-- The includes
-- we may not need resty.http, but including it here is better for memory if we need it
local cjson = require "cjson"
local http = require "resty.http"
local redis = require "resty.redis"
local ssl = require "ngx.ssl"

-- ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~
-- alias functions
local cjson_decode = cjson.decode
local cjson_null = cjson.null
local http_new = http.new
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local ngx_log = ngx.log
local ngx_NOTICE = ngx.NOTICE
local ngx_null = ngx.null
local ngx_say = ngx.say
local ngx_var = ngx.var
local ssl_cert_pem_to_der = ssl.cert_pem_to_der
local ssl_clear_certs = ssl.clear_certs
local ssl_priv_key_pem_to_der = ssl.priv_key_pem_to_der
local ssl_server_name = ssl.server_name
local ssl_set_der_cert = ssl.set_der_cert
local ssl_set_der_priv_key = ssl.set_der_priv_key

-- ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~
-- START: these are just some helper functions


function get_redcon()
	-- this sets up our redis connection
	-- it checks to see if it is a pooled connection (ie, reused) and changes to db9 if it is new
	-- Setup Redis connection
	local redcon = redis:new()
	-- Connect to redis.  NOTE: this is a pooled connection
	local ok, err = redcon:connect("127.0.0.1", "6379")
	if not ok then
		ngx_log(ngx_ERR, "REDIS: Failed to connect to redis: ", err)
		return nil, err
	end
	-- Change the redis DB to #9
	-- We only have to do this on new connections
	local times, err = redcon:get_reused_times()
	if times <= 0 then
		ngx_log(ngx_ERR, "changing to db 9: ", times)
		redcon:select(9)
	end
	return redcon
end


function redis_keepalive(redcon)
	-- put `redcode` into the connection pool
	-- * pool size = 100
	-- * idle time = 10s
	-- note: this will close the connection
	local ok, err = redcon:set_keepalive(10000, 100)
	if not ok then
		ngx_log(ngx_ERR, "failed to set keepalive: ", err)
		return
	end
end


function prime_1__query_redis(redcon, _server_name)
    -- If the cert isn't in the cache, attept to retrieve from Redis
    local key_domain = "d:" .. _server_name
    local domain_data, err = redcon:hmget(key_domain, 'c', 'p', 'i')
    if domain_data == nil then
        ngx_log(ngx_ERR, "`nil` failed to retreive certificates for domain(", key_domain, ") Err: ", err)
        return nil, nil
    end
    if domain_data == ngx_null then
        ngx_log(ngx_ERR, "`ngx_null` failed to retreive certificates for domain(", key_domain, ") Err: ", err)
        return nil, nil
	end    
	-- ngx_log(ngx_ERR, 'err ', err)
	-- ngx_log(ngx_ERR, 'domain_data ', tostring(domain_data))

	-- lua arrays are 1 based!
	local id_cert = domain_data[1]
	local id_pkey = domain_data[2]
	local id_cacert = domain_data[3]

    ngx_log(ngx_DEBUG, "id_cert ", id_cert)
    ngx_log(ngx_DEBUG, "id_pkey ", id_pkey)
    ngx_log(ngx_DEBUG, "id_cacert ", id_cacert)
	
	if id_cert == ngx_null or id_pkey == ngx_null or id_cacert == ngx_null then
        ngx_log(ngx_ERR, "`id_cert == ngx_null or id_pkey == ngx_null or id_cacert == ngx_null for domain(", key_domain, ")")
        return nil, nil
	end
	
	local pkey, err = redcon:get('p'..id_pkey)
    if pkey == nil then
        ngx_log(ngx_ERR, "failed to retreive pkey (", id_pkey, ") for domain (", key_domain, ") Err: ", err)
        return nil, nil
    end

	local cert, err = redcon:get('c'..id_cert)
    if cert == nil or cert == ngx_null then
        ngx_log(ngx_ERR, "failed to retreive certificate (", id_cert, ") for domain (", key_domain, ") Err: ", err)
        return nil, nil
    end

	local cacert, err = redcon:get('i'..id_cacert)
    if cacert == nil or cacert == ngx_null then
        ngx_log(ngx_ERR, "failed to retreive ca certificate (", id_cacert, ") for domain (", key_domain, ") Err: ", err)
        return nil, nil
    end
    
    local fullchain = cert.."\n"..cacert
	return fullchain, pkey
end


function prime_2__query_redis(redcon, _server_name)
    -- If the cert isn't in the cache, attept to retrieve from Redis
    local key_domain = _server_name
    local domain_data, err = redcon:hmget(key_domain, 'p', 'f')
    if domain_data == nil then
        ngx_log(ngx_ERR, "`nil` failed to retreive certificates for domain(", key_domain, ") Err: ", err)
        return nil, nil
    end
    if domain_data == ngx_null then
        ngx_log(ngx_ERR, "`ngx_null` failed to retreive certificates for domain(", key_domain, ") Err: ", err)
        return nil, nil
	end    

	local pkey = domain_data[1]
	local fullchain = domain_data[2]

	if pkey == ngx_null or fullchain == ngx_null then
        ngx_log(ngx_ERR, "`pkey == ngx_null or fullchain == ngx_null for domain(", key_domain, ")")
        return nil, nil
	end
	
	return fullchain, pkey
end


function query_api_upstream(fallback_server, server_name)
	
	local cert, key

	local httpc = http_new()

	local data_uri = fallback_server.."/.well-known/admin/domain/"..server_name.."/config.json?openresty=1"
	ngx_log(ngx_ERR, "querysing upstream API server at: ", data_uri)
	local response, err = httpc:request_uri(data_uri, {method = "GET", })

	if not response then
		ngx_log(ngx_ERR, 'API upstream - no response')
	else 
		local status = response.status
		-- local headers = response.headers
		-- local body = response.body
		if status == 200 then
			local body_value = cjson_decode(response.body)
			-- prefer the multi
			if body_value['server_certificate__latest_multi'] ~= cjson_null then
				cert = body_value['server_certificate__latest_multi']['fullchain']['pem']
				key = body_value['server_certificate__latest_multi']['private_key']['pem']
			elseif body_value['server_certificate__latest_single'] ~= cjson_null then
				cert = body_value['server_certificate__latest_single']['fullchain']['pem']
				key = body_value['server_certificate__latest_single']['private_key']['pem']
			end
		else
			ngx_log(ngx_ERR, 'API upstream - bad response: ', status)
		end
	end
	if cert ~= nil and key ~= nil then
		ngx_log(ngx_ERR, "API cache HIT for: ", server_name)
	else
		ngx_log(ngx_ERR, "API cache MISS for: ", server_name)
	end
	return cert, key
end


-- END helper functions
-- ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~

-- =============================================================================

-- START MAIN LOGIC


function set_ssl_certificate(_cert_cache, _cert_cache_duration, prime_method, fallback_server)

	local server_name = ssl_server_name()

	-- local request debug
	if false then
		ngx_log(ngx_NOTICE, "===========================================================")
		ngx_log(ngx_NOTICE, server_name)
	end

	-- Check for SNI request.
	if server_name == nil then
		ngx_log(ngx_NOTICE, "SNI Not present - performing IP lookup")
	
		-- don't bother with IP lookups
		-- exit out and just fall back on the default ssl cert
		return
	end 

	-- Check cache for certficate
	local cert = _cert_cache:get(server_name .. ":c")
	local key = _cert_cache:get(server_name .. ":k")
	if cert ~= nil and key ~= nil then
		ngx_log(ngx_ERR, "Cert cache HIT for: ", server_name)
	
		if cert == 'x' or key == 'x' then
			ngx_log(ngx_NOTICE, "Previously seen unsupported domain")
	
			-- don't bother with IP lookups
			-- exit out and just fall back on the default ssl cert
			return
		end
	
	else
		ngx_log(ngx_ERR, "Cert cache MISS for: ", server_name)
		
		
		if prime_method ~= nil then
			-- ok, try to get it from redis
			ngx_log(ngx_ERR, "Redis: lookup enabled")
			
			local allowed_prime_methods = {1, 2, }
			if not allowed_prime_methods[prime_method] then
				ngx_log(ngx_ERR, "Redis: invalid `prime_method` not (1, 2) is `", prime_method)
				return
			end

			-- grab redis connection
			local redcon, err = get_redcon()
			if redcon == nil then
	 			ngx_log(ngx_ERR, "Redis: could not get connection")

				-- exit out and just fall back on the default ssl cert
				return
			end
	
			-- actually query redis
			if prime_method == 1 then
				cert, key = prime_1__query_redis(redcon, server_name)
			elseif prime_method == 2 then
				cert, key = prime_2__query_redis(redcon, server_name)
			end

			-- return the redcon to the connection pool
			redis_keepalive(redcon)
		end

		-- let's use a fallback search
		if cert == nil or key == nil then
			if fallback_server ~= nil then
				ngx_log(ngx_ERR, "Upstream API: lookup enabled")
				cert, key = query_api_upstream(fallback_server, server_name)
			end
		end

		if cert ~= nil and key ~= nil then 
	
			-- convert from PEM to der
			cert = ssl_cert_pem_to_der(cert)
			key = ssl_priv_key_pem_to_der(key)
	
			-- Add key and cert to the cache 
			local success, err, forcible = _cert_cache:set(server_name .. ":c", cert, _cert_cache_duration)
			ngx_log(ngx_DEBUG, "Caching Result: ", success, " Err: ",  err)

			local success, err, forcible = _cert_cache:set(server_name .. ":k", key, _cert_cache_duration)
			ngx_log(ngx_DEBUG, "Caching Result: ", success, " Err: ",  err)

			ngx_log(ngx_DEBUG, "Cert and key retrieved and cached for: ", server_name)

		else     
			ngx_log(ngx_ERR, "Failed to retrieve " .. (cert and "" or "cert ") ..  (key and "" or "key "), "for ", server_name)

			-- set a fail marker
			local success, err, forcible = _cert_cache:set(server_name .. ":c", 'x', _cert_cache_duration)
			local success, err, forcible = _cert_cache:set(server_name .. ":k", 'x', _cert_cache_duration)

			-- exit out and just fall back on the default ssl cert
			return
		end
	end

	-- since we have a certs for this server, now we can continue...
	ssl_clear_certs()

	-- Set cert
	local ok, err = ssl_set_der_cert(cert)
	if not ok then
		ngx_log(ngx_ERR, "failed to set DER cert: ", err)
		return
	end

	-- Set key
	local ok, err = ssl_set_der_priv_key(key)
	if not ok then
		ngx_log(ngx_ERR, "failed to set DER key: ", err)
		return
	end
end


function expire_ssl_certs(_cert_cache)
	ngx.header.content_type = 'text/plain'
	local prefix = ngx_var.location
	if ngx_var.request_uri == prefix..'/all' then
		_cert_cache:flush_all()
		ngx_say('{"result": "success", "expired": "all"}')
		return
	end
	local _domain = string.match(ngx_var.request_uri, '^'..prefix..'/domain/([%w-.]+)$')  
	if _domain then
		_cert_cache:delete(_domain)
		ngx_say('{"result": "success", "expired": "domain", "domain": "' .. _domain ..'"}')
		return
	end
	ngx_say('{"result": "error", "expired": "None", "reason": "Unknown URI"}')
	ngx.status = 404
	return
end


local _M = {get_redcon = get_redcon,
			redis_keepalive = redis_keepalive,
			prime_1__query_redis = prime_1__query_redis,
			prime_2__query_redis = prime_2__query_redis,
			query_api_upstream = query_api_upstream,
			set_ssl_certificate = set_ssl_certificate,
			expire_ssl_certs = expire_ssl_certs,
			}

return _M