local random = require 'resty.random'
local ts = require 'threescale_utils'
local redis = require 'resty.redis'
local red = redis:new()

-- As per RFC for Implicit flow: extract params from request uri
-- If implementation deviates from RFC, this function should be over-ridden
function extract_params()
  local params = {}
  local uri_params = ngx.req.get_uri_args()
  
  params.response_type = uri_params.response_type
  params.client_id = uri_params.client_id
  
  if uri_params.redirect_uri then
    params.redirect_uri = uri_params.redirect_uri
  end

  if uri_params.scope then
    params.scope =  uri_params.scope
  end

  if uri_params.state then
    params.state = uri_params.state
  end

  return params
end

-- Check valid credentials
function check_credentials(params)
  local res = check_client_credentials(params)
  return res.status == 200
end

-- Check valid params ( client_id / secret / redirect_url, whichever are sent) against 3scale
function check_client_credentials(params)
  local res = ngx.location.capture("/_threescale/check_credentials",
              { args = { app_id = params.client_id or nil, app_key = params.client_secret or nil, redirect_uri = params.redirect_uri or nil }})
  
  if res.status ~= 200 then   
    params.error = "invalid_client"
    redirect_to_auth(params)
  end

  return { ["status"] = res.status, ["body"] = res.body }
end

-- Authorizes the client for the given scope
function authorize(params)
  local required_params = {'client_id', 'redirect_uri', 'response_type', 'scope'}

  if params["response_type"] ~= 'token' then
    params.error = "unsupported_response_type"
  elseif not ts.required_params_present(required_params, params) then 
    params.error = "invalid_request"
  end

  redirect_to_auth(params)
end

-- redirects_to the authorization url of the API provider with a secret
-- 'state' which will be used when the form redirects the user back to
-- this server.
function redirect_to_auth(params)

  if not params.error then 
    local n = nonce(params.client_id)
    params.state = n 

    params.scope = params.scope
    ts.connect_redis(red)
    local pre_token = generate_access_token(params.client_id)
    params.tok = pre_token

    local ok, err = red:hmset(ngx.var.service_id .. "#tmp_data:".. n,
      {client_id = params.client_id,
      redirect_uri = params.redirect_uri,
      plan_id = params.scope,
      access_token = pre_token})

    if not ok then
      ts.error(ts.dump(err))
    end
  end

  local uri_params = ts.build_query(params)
  
  ngx.header.content_type = "application/x-www-form-urlencoded"
  return ngx.redirect( ngx.var.auth_url .. "?" .. uri_params )
end

-- returns a unique string for the client_id. it will be short lived
function nonce(client_id)
   return ts.sha1_digest(tostring(random.bytes(20, true)) .. "#login:" .. client_id)
end

function generate_access_token(client_id)
   return ts.sha1_digest(tostring(random.bytes(20, true)) .. client_id)
end

local params = extract_params()

local exists = check_credentials(params)

if exists then
  authorize(params)
else
  params.error = "invalid_client"
  redirect_to_auth(params)
end