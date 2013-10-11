#!/usr/bin/ruby

require "json"
require "digest"


class RSApi
	def self.new(envi, account, email, password, api=1.5)
		@cookie = authenticate(envi, account, email, password, api)
		@envi = envi
		return self
	end

	def self.authenticate(envi, account, email, password, api)
		case api
		when 1.0
			`curl -s -c - -u '#{email}':'#{password}' https://#{envi}.rightscale.com/api/acct/#{account}/login?api_version=1.0` =~ /rs_gbl[\s\t]+(.*)\n/
			cookie = $1
			p cookie
			return cookie
		when 1.5
			cookie = Digest::MD5.hexdigest(envi+account+email+password)
			`curl -i -H X_API_VERSION:1.5 -c /tmp/#{cookie} -X POST -d email=#{email} -d 'password=#{password}' -d account_href=/api/accounts/#{account} https://#{envi}.rightscale.com/api/session 2> /dev/nul;`
			return cookie
		end
	end

	def self.getCloud(cloud)
		`curl -s -i -H X_API_VERSION:1.5 -b /tmp/#{@cookie} -X GET\
			https://#{@envi}.rightscale.com/api/clouds/#{cloud} 2> /dev/null`.to_s =~ /(\{.*\})/
		begin
			return JSON.parse($1)
		rescue
			return Hash.new
		end
	end

	def self.getInstance(instance)
		`curl -s -i -H X_API_VERSION:1.5 -b /tmp/#{@cookie} -X GET\
			https://#{@envi}.rightscale.com#{instance} 2> /dev/null`.to_s =~ /(\{.*\})/
		begin
			return JSON.parse($1)
		rescue
			return Hash.new
		end
	end

	def self.getTags(server)
		`curl -s -i -H X_API_VERSION:1.5 -b /tmp/#{@cookie} -X POST -d resource_hrefs[]="#{server}"\
			https://#{@envi}.rightscale.com/api/tags/by_resource 2> /dev/null`.to_s =~ /(\{.*\})/
		begin
			return JSON.parse($1)["tags"]
		rescue
			return Hash.new
		end
	end

	def self.getInstanceHref(cloud, instance)
		`curl -s -i -H X_API_VERSION:1.5 -b /tmp/#{@cookie} -X GET -d filter[]="resource_uid==#{instance}"\
			https://#{@envi}.rightscale.com/api/clouds/#{cloud}/instances 2> /dev/null`.to_s =~ /(\{.*\})/
		begin
			return JSON.parse($1)["links"].select{|l| l["rel"]=="self"}[0]["href"]
		rescue
			return Hash.new
		end
	end

	def self.getDeployment(deployment)
		`curl -s -i -H X_API_VERSION:1.5 -b /tmp/#{@cookie} -X GET\
			https://#{@envi}.rightscale.com#{deployment} 2> /dev/null`.to_s =~ /(\{.*\})/
		begin
			return JSON.parse($1)
		rescue
			return Hash.new
		end
	end

	def self.getServer(server)
		`curl -s -i -H X_API_VERSION:1.5 -b /tmp/#{@cookie} -X GET\
			https://#{@envi}.rightscale.com#{server} 2> /dev/null`.to_s =~ /(\{.*\})/
		begin
			return JSON.parse($1)
		rescue
			return Hash.new
		end
	end

	def self.terminateInstance(instance)
		`curl -s -i -H X_API_VERSION:1.5 -b /tmp/#{@cookie} -X POST\
			https://#{@envi}.rightscale.com#{instance}/terminate 2> /dev/null`.to_s =~ /HTTP\/1.1 ([0-9]{3})/
		 return $1
	end

	def self.terminateServer(server)
		`curl -s -i -H X_API_VERSION:1.5 -b /tmp/#{@cookie} -X POST\
			https://#{@envi}.rightscale.com#{server}/terminate 2> /dev/null`.to_s =~ /HTTP\/1.1 ([0-9]{3})/
		 return $1
	end

	def self.listServers(cloud)
		`curl -s -i -H X_API_VERSION:1.5 -b /tmp/#{@cookie} -X GET -d filter[]="cloud_href==/api/clouds/#{cloud}"\
			https://#{@envi}.rightscale.com/api/servers 2> /dev/null`.to_s =~ /(\[.*\])/
		begin
			return JSON.parse($1)
		rescue
			return Array.new
		end
	end

	def self.listInstances(cloud)
		`curl -s -i -H X_API_VERSION:1.5 -b /tmp/#{@cookie} -X GET \
			https://#{@envi}.rightscale.com/api/clouds/#{cloud}/instances 2> /dev/null`.to_s =~ /(\[.*\])/
		begin
			return JSON.parse($1)
		rescue
			return Array.new
		end
	end
end
