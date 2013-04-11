=begin rdoc

A ServiceResponse is a piece of data generated by a Service. It usually will
be displayed on the resolve menu.

ServiceResponses have a service type, represented by a string. When displaying, ServiceResponses are typically grouped into lists by service type. ServiceResponses are tied to the Service that created them, with the #service accessor.

ServiceResponses have a few basic attributes stored in columns in the db: 'display_text' is the text to put in the hyperlink. 'notes' is available for longer explanatory text (\n in notes will be converted to <br> by view). 'url' can be used to store the url to link to (but see below on linking mechanism). 

[The legacy columns response_key, value_string, value_alt_string and value_text are deprecated and should not be used, but some legacy Services still use them, so they're still there for now].

In addition, there's a Hash (automatically serialized by ActiveRecord) that's stored in service_data, for arbitrary additional data that a Service can store--whatever you want, just put it in. However, there are conventions that Views expect, see below.  You can access ALL the arbitrary key/values in a ServiceResponse, built-in in attributes or from the serialized Hash, by the proxy object returned from #data_values.

You can create a ServiceResponse object with ServiceResponse.create_from_hash, 
where the hash keys may be direct iVar columns, or serialized in the
service_data hash, you don't have to care. 

ServiceResponse is connected to a Request via the ServiceType join table. The data architecture allows a ServiceResponse to be tied to multiple requests, perhaps to support some kind of cacheing re-use in the future. But at present, the code doesn't do this, a ServiceResponse will really only be related to one request. However, a ServiceResponse can be related to a single Request more than once--once per each type of service response. ServiceType is really a three way join, representing a ServiceResponse, attached to a particular Request, with a particular ServiceTypeValue.  


== View Display of ServiceResponse

The resolve menu View expects a Hash (or Hash-like) object with certain conventional keys, to display a particular ServiceResponse. You can provide code in your Service to translate a ServiceResponse to a Hash. But you often don't need to, you can use the proxy object returned by #data_values instead, which provides hash-like access to all arbitrary key/values stored in ServiceResponse. If the Service stores properties in there using conventional keys (see below), no further translation is needed.

However, if you need to do further translation you can implement methods on the Service, of the form: "to_[service type string](response)", for instance "to_fulltext". Umlaut will give it a ServiceResponse object, method should return a hash (or hash-like obj).  Service can also implement a method response_to_view_data(response), as a 'default' translation. This mechanism of various possible 'translations' is implemented by Service#view_data_from_service_type.

== Url generation

At the point the user clicks on a ServiceResponse, Umlaut will attempt to find a url for the ServiceResponse, by calling response_url(response) on the relevant Service. The default implementation in service.rb just returns service_response['url'], so the easiest way to do this is just to put the url in service_response['url'].  However, your Service can over-ride this method to provide it's own implementation to generate to generate the url on demand in any way it wants.  If it does this, technically service_response['url'] doesn't need to include anything. But if you have a URL, you may still want to put it there, for Umlaut to use in guessing something about the destination, for de-duplication and possibly other future purposes.  

= Conventional keys:

 Absolute minimum: 
 [:display_text]   Text that will be used 

 Basic set (used by fulltext and often others)
 [:display_text]
 [:notes]          (newlines converted to <br>)
 [:coverage]
 [:authentication]
 [:match_reliability] => One of MatchExact or MatchUnsure (maybe more later), for whether there's a chance this is an alternate Edition or the wrong work entirely. These are fuzzy of neccisity -- if it MIGHT be an alt edition, use MatchAltEdition even if you can't be sure it's NOT an exact match. 
 :edition_str => String statement of edition or work to let the user disambiguate and see if it's what they want. Can be taken for instance from Marc 260. Generally only displayed when match_reliabilty is not MatchExact. If no value, Umlaut treats as MatchExact.

== Full text specific
These are applicable only when the incoming OpenURL is an article-level citation. Umlaut uses Request#title_level_citation? to estimate this.

  [:coverage_checked]  boolean, default true.  False for links from, eg, the catalog, where we weren't able to pre-check if the particular citation is included at this link.
  [:can_link_to_article] boolean, default true. False if the links is _known_ not to deliver user to actual article requested, but just to a title-level page. Even though SFX links sometimes incorrectly do this, they are still not set to false here.  
  
== Coverage dates
Generally only for fulltext. Right now only supplied by SFX. 

  [:coverage_begin_date]  Ruby Date object representing start of coverage
  [:coverage_end_date]  Ruby Date object representing end of coverage
 
== highlighted_link (see also)
 [:source]   (optional, otherwise service's display_name is used)

== Holdings set adds:
 [:source_name]
 [:call_number]
 [:status]
 [:request_url]     a url to request the item. optional. 
 [:coverage_array] (Array of coverage strings.)
 [:due_date]
 [:collection_str]
 [:location_str]

== search_inside
 Has no additional conventional keys, but when calling it's url handling functionality, send it a url param query= with the users query. In the API, this means using the umlaut_passthrough_url, but adding a url parameter query on to it. This will redirect to the search results. 

== Cover images:
 [:display_text] set to desired alt text
 [:url]    src url to img
 [:size]  => 'small', 'medium', 'large' or 'extra-large'. Also set in :key

== Anything from amazon:
 [:asin]

== Abstracts/Tocs:
   Can be a link to, or actual content. Either way, should be set
   up to link to source of content if possible. Basic set, plus:
   [:content]           actual content, if available.
   [:content_html_safe] Set to true if content includes html which should be
                        passed through un-escaped. Service is responsible
                        for making sure the HTML is safe from injection
                        attacks (injection attacks from vendor API's? Why not?).
                        ActionView::Helpers::SanitizeHelper's #sanitize
                        method can convenient. 

=end
class ServiceResponse < ActiveRecord::Base  
  @@built_in_fields = [:display_text, :url, :notes, :response_key, :value_string, :value_alt_string, :value_text, :id]
  belongs_to :request
  serialize :service_data  
  # This value is not stored in db, but is set temporarily so
  # the http request params can easily be passed around with a response
  # object.
  attr_accessor :http_request_params

  # Constants for 'match_reliability' value.
  MatchExact = 'exact'
  MatchUnsure = 'unsure'
  #MatchAltEdition = 'edition'
  #MatchAltWork = 'work'

  def initialize(params = nil)
    super(params)
    self.service_data = {} unless self.service_data
  end
  
  # Create from a hash of key/values, where some keys
  # may be direct iVars, some may end up serialized in service_data, 
  # you don't have to care, it will do the right thing. 
  def self.create_from_hash(hash)
    r = ServiceResponse.new
    r.take_key_values(hash)
    return r
  end

  # Instantiates and returns a new Service associated with this response.
  def service
    @service ||= ServiceStore.instantiate_service!( self.service_id, nil )
  end
  
  # Returns a hash or hash-like object with properties for the service response. 
  def view_data
    self.service.view_data_from_service_type(self)
  end
  
  
  def service_data
    # Fix weird-ass char encoding bug with AR serialize and hashes.
    # https://github.com/rails/rails/issues/6538
    data = super
    if data.kind_of? Hash
      data.values.each {|v| v.force_encoding "UTF-8"  if v.respond_to? :force_encoding  }
    end
    return data
  end
  
    # Should take a ServiceTypeValue object, or symbol name of
  # ServiceTypeValue object. 
  def service_type_value=(value)
    value = ServiceTypeValue[value] unless value.kind_of?(ServiceTypeValue)        
    self.service_type_value_name = value.name   
  end
  def service_type_value
    ServiceTypeValue[self.service_type_value_name]
  end
  
  

  def take_key_values(hash)    
    # copy it, cause we're gonna modify it
    hash = hash.clone
    hash.each_pair do |key, value|
      if ( self.class.built_in_fields.include?(key))
        self.send(key.to_s + '=', value)
        hash.delete(key)
      end
    end
    # What's left is arbitrary key/values that go in service_data
    init_service_data(hash)
  end

  def init_service_data(hash)
    hash.each {|key, value| data_values[key] = value} if hash
  end

  def data_values    
    # Lazy load, and store a reference. Don't worry, ruby
    # GC handles circular references no problem. 
    unless (@data_values_proxy)  
      @data_values_proxy = ServiceResponseDataValues.new(self)
    end
    return @data_values_proxy;
  end

  def self.built_in_fields
    @@built_in_fields
  end
  

  
end

# A proxy-like class, to provide hash-like access to all arbitrary
# key/value pairs stored in a ServiceResponse, whether they key/value
# is stored in an ActiveRecord attribute (#built_in_fields) or in
# the serialized hash in the service_data attribute. 
# Symbols passed in will be 'normalized' to strings before being used as keys.
# So symbols and strings are interchangeable. Normally, keys should be symbols.
class ServiceResponseDataValues
  def initialize(arg_service_response)
    @service_response = arg_service_response
  end

  def [](key)        
    if ServiceResponse.built_in_fields.include?(key)
      return @service_response.send(key)
    else
      return @service_response.service_data[key]
    end
  end

  def []=(key, value)
    if(ServiceResponse.built_in_fields.include?(key))
      @service_response.send(key.to_s+'=', value)
    else
      @service_response.service_data[key] = value
    end
  end
  
end
