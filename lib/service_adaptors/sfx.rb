# config parameters in services.yml
# name: display name
# base_url
# click_passthrough: When set to true, Umlaut will send all SFX clicks through SFX, for SFX to capture statistics. This is currently done using a backdoor into the SFX sfxresolve.cgi script. Defaults to false, or the app_config.sfx_click_passthrough value. 

class Sfx < Service
  require 'uri'
  require 'open_url'
  
  def handle(request)
    client = self.initialize_client(request)
    begin
      response = self.do_request(client)
      self.parse_response(response, request)
      return request.dispatched(self, true)
    rescue Errno::ETIMEDOUT
      # Request to SFX timed out. Record this as unsuccesful in the dispatch table. 
      return request.dispatched(self, false)
    end
  end
  def initialize_client(request)
    transport = OpenURL::Transport.new(@base_url)
    context_object = request.referent.to_context_object
    context_object.referrer.set_identifier(request.referrer.identifier)if request.referrer
    transport.add_context_object(context_object)
    transport.extra_args["sfx.response_type"]="multi_obj_xml"
    @get_coverage = false
    unless context_object.referent.metadata.has_key?("issue") or context_object.referent.metadata.has_key?("volume") or context_object.referent.metadata.has_key?("date")    
      transport.extra_args["sfx.ignore_date_threshold"]="1"
      transport.extra_args["sfx.show_availability"]="1"
      @get_coverage = true
    end  
    if context_object.referent.identifier and context_object.referent.identifier.match(/^info:doi\//)
      transport.extra_args['sfx.doi_url']='http://dx.doi.org'
    end
    return transport
  end
  
  def do_request(client)
    client.transport_inline
    return client.response
  end
  
  def parse_response(resolver_response, request)
    require 'hpricot'
    require 'cgi'
    doc = Hpricot(resolver_response)     
    # parse perl_data from response
    related_items = []
    attr_xml = CGI.unescapeHTML((doc/"/ctx_obj_set/ctx_obj/ctx_obj_attributes").inner_html)
    perl_data = Hpricot(attr_xml)
    (perl_data/"//hash/item[@key='@sfx.related_object_ids']").each { | rel | 
      (rel/'/array/item').each { | item | 
        related_items << item.inner_html
      } 
    }
    
    object_id_node = (perl_data/"//hash/item[@key='rft.object_id']")
    object_id = nil
    if object_id_node
      object_id = object_id_node.inner_html
    end
    
    metadata = request.referent.metadata
    
    enhance_metadata(request, metadata, perl_data)

    request_id = nil
    request_id_node = (perl_data/"//hash/item[@key='sfx.request_id']") 
    if request_id_node
      request_id = request_id_node.inner_html
    end    

    if object_id
      journal = Journal.find_by_object_id(object_id)
    elsif request.referent.metadata['issn']
      journal = Journal.find_by_issn_or_eissn(request.referent.metadata['issn'], request.referent.metadata['issn'])
    end  
    if journal
      journal.categories.each do | category |
        request.add_service_response({:service=>self,:key=>'SFX',:value_string=>category.category,:value_text=>category.subcategory},['subject'])
      end
    end

    # Each target delivered by SFX
    (doc/"/ctx_obj_set/ctx_obj/ctx_obj_targets/target").each_with_index do|target, target_index|  


      value_text = {}

      sfx_service_type = (target/"/service_type").inner_html
      if (sfx_service_type == "getFullTxt" || sfx_service_type == "getDocumentDelivery")

        if (target/"/displayer")
          source = "SFX/"+(target/"/displayer").inner_html
        else
          source = "SFX"+URI.parse(self.url).path
        end
        
        coverage = nil
        if (sfx_service_type == "getFullTxt" && @get_coverage )
          if journal 
            cvg = journal.coverages.find(:first, :conditions=>['provider = ?', (target/"/target_public_name").inner_html])
            coverage = cvg.coverage if cvg
          end
        end

        if ( sfx_service_type == "getFullTxt")
          value_string = (target/"/target_service_id").inner_html
          umlaut_service = 'fulltext'
        else
          value_string = request_id
          umlaut_service = 'document_delivery'
        end
        
        value_text[:url] = CGI.unescapeHTML((target/"/target_url").inner_html)
        value_text[:notes] = CGI.unescapeHTML((target/"/note").inner_html)
        value_text[:source] = source
        value_text[:covarege] = coverage if coverage

        # Sfx metadata we want
        value_text[:sfx_target_index] = target_index + 1 # sfx is 1 indexed
        value_text[:sfx_request_id] = (perl_data/"//hash/item[@key='sfx.request_id']").first.inner_html
        value_text[:sfx_target_service_id] = (target/"target_service_id").inner_html
        # At url-generation time, the request isn't available to us anymore,
        # so we better store this citation info here now, since we need it
        # for sfx click passthrough
        value_text[:citation_year] = metadata['date'] 
        value_text[:citation_volume] = metadata['volume'];
        value_text[:citation_issue] = metadata['issue']
        value_text[:citation_spage] = metadata['spage']
        

        request.add_service_response({:service=>self,:key=>(target/"/target_public_name").inner_html,:value_string=>value_string,:value_text=>value_text.to_yaml},[umlaut_service])
      end
    end   
  end
  
  def to_fulltext(response)  
    value_text = YAML.load(response.value_text)     
    return {:display_text=>response.response_key, :note=>value_text[:note],:coverage=>value_text[:coverage],:source=>value_text[:source]}
  end
  
  def response_to_view_data(response)
    # default for any type, same as to_fulltext
    return to_fulltext(response)
  end
  
  def sfx_click_passthrough
    # From config, or if not that, from app default, or if not that, default
    # to false. 
    return @click_passthrough || AppConfig.default_sfx_click_passthrough || false;
  end
  
  def response_url(response)

    customData = YAML.load(response.value_text)
              
    if ( ! self.sfx_click_passthrough )
      return CGI.unescapeHTML(customData[:url])
    else
      # Okay, wacky abuse of SFX undocumented back-ends to pass the click
      # through SFX, so statistics are captured by SFX. 
      
      sfx_resolver_cgi_url =  @base_url + "/cgi/core/sfxresolver.cgi"      
      # Not sure if fixing tmp_ctx_obj_id to 1 is safe, but it seems to work,
      # and I don't know what the value is or how else to know it. 
      dataString = "?tmp_ctx_svc_id=#{customData[:sfx_target_index]}"
      dataString += "&tmp_ctx_obj_id=1&service_id=#{customData[:sfx_target_service_id]}"
      dataString += "&request_id=#{customData[:sfx_request_id]}"
      dataString += "&rft.year="
      dataString += customData[:citation_year].to_s if customData[:citation_year]
      dataString += "&rft.volume="
      dataString += customData[:citation_volume].to_s if customData[:citation_volume]
      dataString += "&rft.issue="
      dataString += customData[:citation_issue].to_s if customData[:citation_issue]
      dataString += "&rft.spage="
      dataString += customData[:citation_spage].to_s if customData[:citation_issue]

      return sfx_resolver_cgi_url + dataString       
    end
  end


  protected
  def enhance_metadata(request, metadata, perl_data)

    if request.referent.format == 'journal'
      unless metadata["jtitle"]
        jtitle_node = (perl_data/"//hash/item[@key='rft.jtitle']")
        if jtitle_node
          request.referent.enhance_referent('jtitle', jtitle_node.inner_html) 
        end
      end
    end
    if request.referent.format == 'book'
      unless metadata["btitle"]
        btitle_node = (perl_data/"//hash/item[@key='rft.btitle']")
        if btitle_node
          request.referent.enhance_referent('btitle', btitle_node.inner_html) 
        end
      end
    end    
    issn_node = (perl_data/"//hash/item[@key='rft.issn']")
    if issn_node
      unless metadata['issn'] 
        request.referent.enhance_referent('issn', issn_node.inner_html)
      end
    end    
    eissn_node = (perl_data/"//hash/item[@key='rft.eissn']")
    if eissn_node
      unless metadata['eissn'] 
        request.referent.enhance_referent('eissn', eissn_node.inner_html)
      end
    end      
    isbn_node = (perl_data/"//hash/item[@key='rft.isbn']")
    if isbn_node
      unless metadata['isbn'] 
        request.referent.enhance_referent('isbn', isbn_node.inner_html)
      end
    end  
    genre_node = (perl_data/"//hash/item[@key='rft.genre']")
    if genre_node 
      unless metadata['genre']
        request.referent.enhance_referent('genre', genre_node.inner_html)
      end
    end    
    
    issue_node = (perl_data/"//hash/item[@key='rft.issue']")
    if issue_node 
      unless metadata['issue']
        request.referent.enhance_referent('issue', issue_node.inner_html)
      end
    end      
    vol_node = (perl_data/"//hash/item[@key='rft.volume']")
    if vol_node 
      unless metadata['volume']
        request.referent.enhance_referent('volume', vol_node.inner_html)
      end
    end      
  end


  
end
