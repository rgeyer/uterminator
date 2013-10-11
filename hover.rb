#!/usr/bin/ruby

require 'rubygems'
require 'rest_connection'
require 'mysql'
require 'trollop'
require 'time'
load 'rsapi.rb'

@safewords = ["monkey", "save", "slave"]

@opts = Trollop::options do
	opt :config, "Location of configuration file", :type => :string
	opt :server_life, "Lifespan of a server in hours", :type => :string
	opt :debug, "Enable debug output", :type => :boolean
	opt :instance, "Terminate raw instances", :type => :boolean
	opt :dryrun, "Don't terminate anything", :type => :boolean
end

@config = Hash.new()

def parseConfig(config_location)
	puts "Parsing #{config_location}" if @opts[:debug]

	raw = File.open(config_location)
	raw.each do |config_line|
		config_line.chomp!()
		key, value = config_line.split("=")
		@config[key]=value
	end
	if !@config["api_username"] or !@config["api_password"] or !@config["api_environments"] or !@config["api_accounts"] or !@config["api_clouds"] \
	   or !@config["db_username"] or !@config["db_password"] or !@config["db_name"] or !@config["db_host"]
		raise "Required config parameters missing"
	end
end

def getLink(i, link_type)
	begin
		i["links"].each do |link|
			if link["rel"] == link_type
				return link["href"]
			end	
		end
	rescue
		return ""
	end
end

def getCloud(s)
	getLink(s, "current_instance") =~ /([0-9]+)/
	return $1
end

def processServers(account, db, environment, cloud)
	puts "Processing servers" if @opts[:debug]
	servers = account.listServers(cloud).select{|s| s["state"] !~ /(nil|terminated|stopped|inactive)/}

	servers.each do |s|
		instance_href = getLink(s, "current_instance")
		st_uuid = getLink(s, "self")

		instance_uuid = account.getInstance(instance_href)["resource_uid"]

		db_result = db.query("select uuid from t101 where uuid='#{instance_uuid}'")
		if db_result.num_rows == 0
			puts "--Server #{s["name"]} not found in DB" if @opts[:debug]
		else
			puts "--DB entry for #{s["name"]} exists, adding data" if @opts[:debug]
			db.query("update t101 set st_uuid='#{st_uuid}', cloud='#{cloud}', env='#{environment}' where uuid='#{instance_uuid}'")

		end
	end
	
end

def processInstances(db)
	puts "Processing instances" if @opts[:debug]
	@config["api_environments"].split(",").each do |api_environment|
		@config["api_accounts"].split(",").each do |api_account|
			puts "--Connection to #{api_environment}/#{api_account}"
			account = RSApi.new(api_environment, api_account, @config["api_username"], @config["api_password"])
			@config["api_clouds"].split(",").each do |api_cloud|
				puts "----Getting instances #{api_cloud}"
				instances = account.listInstances(api_cloud).select{|i| i["state"] !~ /(nil|terminated|stopped|inactive)/ and i["state"] =~ /[A-z0-9]/}
				instances.each do |i|
					uuid = i["resource_uid"]
					name = i["name"]
					state= i["state"]
					locked= i["locked"]
					if locked == true
						locked = "NOW()"
					else
						locked = "NULL"
					end
					puts "------Instance: #{name}, uuid: #{uuid} found on cloud #{api_cloud}" if @opts[:debug]
					db_result = db.query("select uuid from t101 where uuid='#{uuid}'")
					if db_result.num_rows == 0
						db.query("insert into t101 values('#{uuid}', NULL, '#{api_account}', '#{api_cloud}', NULL, NOW(), NOW(), NULL, #{locked})")
						puts "--------Adding db entry for #{uuid} (state #{state})" if @opts[:debug]
					else
						puts "--------DB entry for #{uuid} exists; adding data" if @opts[:debug]
						db.query("update t101 set updated_at=NOW() where uuid='#{uuid}'")
						db.query("update t101 set locked_at=NOW() where uuid='#{uuid}'") if locked == "NOW()"

					end
				end
				processServers(account, db, api_environment, api_cloud)
			end
		end
	end
end

def runReport(db)
	puts "Running Report" if @opts[:debug]
	@config["api_environments"].split(",").each do |api_environment|
		@config["api_accounts"].split(",").each do |api_account|
			puts "--Connection to #{api_environment}/#{api_account}"
			account = RSApi.new(api_environment, api_account, @config["api_username"], @config["api_password"])
			@config["api_clouds"].split(",").each do |api_cloud|
				db_result = db.query("select uuid,discovered_at from t101 where cloud='#{api_cloud}' and acct='#{api_account}' and terminated_at is NULL and st_uuid is NULL")
				db_result.each do |row|
					instance_href = account.getInstanceHref(api_cloud,row[0])
					discovered_at = Time.parse(row[1])
					extratime=0

					server = account.getServer(row[2])
					tags = account.getTags(instance_href)
					tag = tags.select{|tag| tag["name"] =~ /terminator:save=(.*)/}
					if tag.size > 0
						tag[0]["name"] =~ /terminator:save=(.*)/
						extratime = $1.to_i * 60 * 60
					end

					server = account.getInstance(instance_href)
					runtime = (Time.now - discovered_at)/60/60
					if runtime > 24
						puts "----StillAlive: #{server["name"]} has been running for #{runtime} hours"
					end
				end
			end
		end
	end
end

def terminateInstances(db)
	puts "Terminating raw instances" if @opts[:debug]
	@config["api_environments"].split(",").each do |api_environment|
		@config["api_accounts"].split(",").each do |api_account|
			puts "--Connection to #{api_environment}/#{api_account}"
			account = RSApi.new(api_environment, api_account, @config["api_username"], @config["api_password"])
			@config["api_clouds"].split(",").each do |api_cloud|
				db_result = db.query("select uuid,discovered_at,st_uuid,locked_at from t101 where cloud='#{api_cloud}' and acct='#{api_account}' and terminated_at is NULL and st_uuid is NULL")
				db_result.each do |row|
					instance_href = account.getInstanceHref(api_cloud,row[0])
					discovered_at = Time.parse(row[1])
					begin
						locked_at = Time.parse(row[3])
					rescue
						locked_at = Time.parse("1900-01-01")
					end
					extratime=0

					server = account.getServer(row[2])
					tags = account.getTags(instance_href)
					tag = tags.select{|tag| tag["name"] =~ /terminator:save=(.*)/}
					if tag.size > 0
						tag[0]["name"] =~ /terminator:save=(.*)/
						extratime = $1.to_i * 60 * 60
					end

					if Time.new - discovered_at > @opts[:server_life].to_i * 60 * 60 + extratime
						server = account.getInstance(instance_href)
						next if server == Hash.new()
						#if not @safewords.any?{|word| server["name"] =~ /#{word}/i} and (Time.new - locked_at) > 2 * 60 * 60
						if not safeWordProtected(server["name"], "") and (Time.new - locked_at) > 2 * 60 * 60
							cloud_name = account.getCloud(api_cloud)["name"]
							puts "----Terminating instance #{server["name"]} (#{row[0]}) from #{cloud_name}"
							terminateInstance(api_cloud, instance_href, server["name"], account, db)
							#termination_status = account.terminateInstance(instance_href) if not @opts[:dryrun]
							#p termination_status if @opts[:debug]
							#db.query("update t101 set terminated_at=NOW() where uuid='#{row[0]}'") if termination_status == "204" 
						else
							puts "----#{server["name"]} is protected by lock" if (Time.new - locked_at) < 2 * 60 * 60
							puts "----#{server["name"]} is protected by a safe word" if safeWordProtected(server["name"], "")
						end
					else
						puts "----Instance #{server["name"]} is too young to terminate"
					end
				end
			end
		end
	end
end

def listDBServers(db, api_cloud, api_environment, api_account)
	return db.query("select uuid,discovered_at,st_uuid,locked_at from t101 where cloud='#{api_cloud}' and env='#{api_environment}' and acct='#{api_account}' and terminated_at is NULL and st_uuid is not NULL")
end

def getExtraTime(account, server_href)
	begin
		server = account.getServer(server_href)
		tags = account.getTags(getLink(server,"current_instance"))
		tag = tags.select{|tag| tag["name"] =~ /terminator:save=(.*)/}
	rescue
		tag = Array.new
	end
	if tag.size > 0
		tag[0]["name"] =~ /terminator:save=(.*)/
		extratime = $1.to_i * 24 * 60 * 60
	else
		extratime = 0
	end

	return extratime
end

def isOld(discovered_at, extra_time)
	#puts "Age: #{Time.new - discovered_at}; Life: #{@opts[:server_life].to_i * 60 * 60}; Extra Time: #{extra_time}" if @opts[:debug]
	if Time.new - discovered_at > @opts[:server_life].to_i * 60 * 60 + extra_time
		return true
	else
		return false
	end
end

def getDeploymentName(account, server)
	begin
		deployment_href = server["href"].select{|h| h["rel"] == "deployment"}[0]
		deployment = account.getDeployment(deployment_href)
		return deployment["name"]
	rescue
		return ""
	end

end

def safeWordProtected(server_name, deployment_name)
	if @safewords.any?{|word| server_name =~ /#{word}/i or deployment_name =~ /#{word}/i}
		return true
	else
		return false
	end
end

def terminateInstance(api_cloud, instance_uuid, server_name, account, db)
	termination_status = account.terminateInstance(account.getInstanceHref(api_cloud, instance_uuid)) if not @opts[:dryrun]
	puts termination_status if @opts[:debug]
	if termination_status == "204"
		cloud_name = account.getCloud(api_cloud)["name"]
		`echo "Be sure to lock the server or put save somewhere in the nickname to prevent pwnage from the terminator" | mail -s "#{server_name} from #{cloud_name} has been destroyed by UTerminator" engineering@rightscale.com white.sprint@rightscale.com silver.sprint@rightscale.com`
		#`echo "Be sure to lock the server or put save somewhere in the nickname to prevent pwnage from the terminator" | mail -s "#{server_name} from #{cloud_name} has been destroyed by UTerminator" bill.rich@rightscale.com nicholas.bedi@rightscale.com`
		db.query("update t101 set terminated_at=NOW() where uuid='#{instance_uuid}'")
	end

end

def terminateServers(db)
	puts "Terminating servers" if @opts[:debug]
	@config["api_environments"].split(",").each do |api_environment|
		@config["api_accounts"].split(",").each do |api_account|
			puts "--Connection to #{api_environment}/#{api_account}"
			account = RSApi.new(api_environment, api_account, @config["api_username"], @config["api_password"])
			@config["api_clouds"].split(",").each do |api_cloud|
				db_result = listDBServers(db, api_cloud, api_environment, api_account)
				db_result.each do |row|
					begin
						locked_at = Time.parse(row[3])
					rescue
						locked_at = Time.parse("1900-01-01")
					end

					st_href = row[2]
					instance_uuid = row[0]
					discovered_at = Time.parse(row[1])
					server = account.getServer(st_href)
					next if server == Hash.new()
					server_name = server["name"]

					extratime=getExtraTime(account, st_href)

					if isOld(discovered_at, extratime)
						deployment_name = getDeploymentName(account, server)
						if not safeWordProtected(server_name, deployment_name) and (Time.new - locked_at) > 2 * 60 * 60
							puts "----Terminating #{server_name} (#{instance_uuid})"
							terminateInstance(api_cloud, instance_uuid, server_name, account, db)
						else
							puts "----#{server_name} is protected by lock" if (Time.new - locked_at) < 2 * 60 * 60
							puts "----#{server_name} is protected by a safe word" if safeWordProtected(server_name, deployment_name)
						end
					else
						puts "----Server #{server_name} #{instance_uuid} is too young to terminate"
					end
				end
			end
		end
	end

end

def cleanDB(db, purge)
	puts "Cleaning DB"
	result = db.query("select uuid,updated_at from t101 where terminated_at is NULL")
	result.each do |row|
		updated = Time.parse(row[1])
		if Time.now - updated > purge.to_i * 60 * 60
			puts "--Dropping #{row[0]} from DB"
			db.query("delete from t101 where uuid='#{row[0]}'")
		end
	end
end

parseConfig(@opts[:config])
db = Mysql::new(@config["db_host"], @config["db_username"], @config["db_password"], @config["db_name"])


processInstances(db)
terminateInstances(db) if @opts[:instance]
terminateServers(db)

cleanDB(db,24)
#runReport(db)
