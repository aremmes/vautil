class VAUtil
  class Server
    # Taken from voiceaxis/application/models/Server.inc.php
    TYPE_NONE         = 0
    TYPE_APPLICATION  = 1
    TYPE_SBC          = 2
    TYPE_FEATURE      = 3
    TYPE_SIP_TRUNK    = 4
    TYPE_MEDIA        = 5
    TYPE_FAX          = 6
    TYPE_API          = 7
    TYPE_PROVISIONING = 8

    STATUS_INACTIVE      = 0
    STATUS_ACTIVE_OPEN   = 1
    STATUS_ACTIVE_CLOSED = 2

    attr_reader :id, :fqdn, :hostname, :ip, :type, :platform

    def initialize(id, fqdn, ip, type, platform=nil)
      @id = id
      @fqdn = fqdn
      @hostname = fqdn.split('.')[0]
      @ip = ip
      @type = type
      @platform = platform
    end
  end
end
