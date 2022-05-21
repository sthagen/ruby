# frozen_string_literal: false
# Net::HTTP exception class.
# You cannot use Net::HTTPExceptions directly; instead, you must use
# its subclasses.
module Net::HTTPExceptions
  def initialize(msg, res)   #:nodoc:
    super msg
    @response = res
  end
  attr_reader :response
  alias data response    #:nodoc: obsolete
end
class Net::HTTPError < Net::ProtocolError
  include Net::HTTPExceptions
end
class Net::HTTPRetriableError < Net::ProtoRetriableError
  include Net::HTTPExceptions
end
class Net::HTTPClientException < Net::ProtoServerError
  include Net::HTTPExceptions
end

# for compatibility
Net::HTTPServerException = Net::HTTPClientException # :nodoc:
# We cannot use the name "HTTPServerError", it is the name of the response.

class Net::HTTPFatalError < Net::ProtoFatalError
  include Net::HTTPExceptions
end

module Net
  deprecate_constant(:HTTPServerException)
end
