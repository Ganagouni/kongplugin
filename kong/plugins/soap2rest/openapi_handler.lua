------------------------------------------------------------------------------
-- kong-plugin-soap2rest 1.0.2-1
------------------------------------------------------------------------------
-- Copyright 2021 adesso SE
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
------------------------------------------------------------------------------
-- Author: Daniel Kraft <daniel.kraft@adesso.de>
------------------------------------------------------------------------------

local lyaml   = require "lyaml"

local utils = require "kong.plugins.soap2rest.utils"

--local inspect = require "inspect"

local _M = {}

-- Builds the REST request path
-- @param plugin_conf Plugin configuration
-- @param RequestAction SOAP OperationId
-- @retrun  1. HTTP-Action
--          2. REST-Request path
local function getRequestPath(plugin_conf, RequestAction)
    local action, RequestPath= "", ""
    for word in string.gmatch(RequestAction, "%u%l*") do
        word = string.lower(word)
        if word == "get" or word == "post" or word == "delete" or word == "put" then
            action = word
        else
            RequestPath = RequestPath..word.."/"
        end
    end

    RequestPath = string.sub(RequestPath, 1, -2)

    if plugin_conf.operation_mapping ~= nil and plugin_conf.operation_mapping[RequestAction] ~= nil then
        RequestPath = plugin_conf.operation_mapping[RequestAction]
    end

    return action, plugin_conf.rest_base_path..RequestPath
end

-- Identifying the content type of the request and response of a REST operation
-- @param operationName OperationId
-- @param operation Excerpt from the OpenAPI
-- @retrun  1. Content-Type of the request
--          2. Content-Type of the response
local function parseOperation(operationName, operation)
    local request, response = {type = "application/json"}, {type = "application/json"}
    if operation.requestBody ~= nil then
        kong.log.debug("Parsing body of the operation: "..operationName)

        -- Identification of the content type of the request
        if operation["x-contentType"] ~= nil then
            kong.log.debug("Found x-contenttype")
            request.type = operation["x-contentType"]
        else
            request.type = next(operation.requestBody.content)
            kong.log.debug("Use plain content: "..request.type)
        end

        -- Identification of the encoding if it is a file
        if string.find(request.type, "multipart/") ~= nil then
            kong.log.debug("Found Multipart: "..request.type)
            local encoding = operation.requestBody.content[request.type].encoding
            request["encoding"] = {
                file = encoding.datei.contentType,
                meta = encoding.metadaten.contentType
            }

            kong.log.debug("Encoding: file = "..encoding.datei.contentType..", meta = "..encoding.metadaten.contentType)
        end
    end
    kong.log.debug("Request Type: "..request.type)

    -- Identification of the content type of the response
    if (operation.responses ~= nil and operation.responses["200"] ~= nil) then
        response.type = next(operation.responses["200"].content)
    elseif (operation.responses ~= nil and operation.responses[200] ~= nil) then
        response.type = next(operation.responses[200].content)
    end
    kong.log.debug("Response Type: "..response.type)

    return request, response
end

-- Analysing the OpenAPI file
-- @param plugin_conf Plugin configuration
function _M.parse(plugin_conf)
    -- Reading out the OpenAPI file
    local status, yaml_content = pcall(utils.read_file, plugin_conf.openapi_yaml_path)
    if not status then
        kong.log.err("Unable to read OpenAPI file '"..plugin_conf.openapi_yaml_path.."' \n\t", yaml_content)
        return
    end

    -- Converting the OpenAPI file into a Lua table
    local status, openapi_table = pcall(lyaml.load, yaml_content)
    if not status then
        kong.log.err("Unable to parse OpenAPI yaml\n\t", openapi_table)
        return
    end

    -- Completing the cached plugin configuration
    for requestAction, operation in pairs(plugin_conf.operations) do
        local action, path = getRequestPath(plugin_conf, requestAction)

        for key, value in pairs(openapi_table.paths) do
            kong.log.debug("API Path: "..key)
            if string.find(path, key) then
                local status, request, response = pcall(parseOperation, action, value[action])

                if status then
                    operation["rest"] = {
                        action = action,
                        path = path,
                        request = request,
                        response = response
                    }
                else
                    kong.log.debug("Error While Parsing Method: "..tostring(request))
                    operation["rest"] = {
                        action = action,
                        path = path
                    }
                end
                break
            end
        end
    end
end

return _M