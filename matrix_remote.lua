-- Optional CC:Tweaked transport. Only the fixed computer's owner loop calls
-- open/publish/process. capture is deliberately device-free and never yields.
-- Computer-ID filtering is not encryption or authentication.
local M = {PROTOCOL = "matrix_remote_v1"}
local ACTIONS = {auto=true,pause=true,resume=true,scram=true,reset=true,max_minus=true,max_plus=true}
local SIDES = {top=true,bottom=true,left=true,right=true,front=true,back=true}
local serial = 0
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function integer(n) return finite(n) and n>=1 and n<=2147483647 and n%1==0 end
local function token(s) return type(s)=="string" and #s>=1 and #s<=128 end
local function copy(value, depth, budget)
    if type(value)=="table" then
        if depth>8 or budget.n>512 then return nil end
        local result={}
        for k,v in pairs(value) do
            budget.n=budget.n+1
            if budget.n>512 then break end
            if type(k)=="string" or type(k)=="number" then result[k]=copy(v,depth+1,budget) end
        end
        return result
    elseif type(value)=="string" then return value:sub(1,1024)
    elseif type(value)=="boolean" or finite(value) then return value end
end
local function frozen(value) return copy(value,0,{n=0}) end
local function unique(prefix, clock)
    serial=serial+1
    local stamp=clock()
    if os and os.epoch then local ok,v=pcall(os.epoch,"utc");if ok then stamp=v end end
    return prefix..":"..tostring(stamp)..":"..serial..":"..tostring({}):gsub("table: ","")
end

function M.create(context)
    context=context or {}
    local clock=context.clock or os.clock
    local allowed,peers,pending,history={},{},{},{}
    for _,id in ipairs(context.allowedClients or {3}) do
        if type(id)=="number" and id>=0 and id%1==0 then allowed[id]=true end
    end
    local count,seq,epoch=0,0,0
    local latest,signature,side,nextOpen,interrupted=nil,nil,nil,-math.huge,false
    local hostSession=unique("host",clock)
    local self={}
    local function network(fn,...)
        local ok,result=pcall(fn,...)
        if not ok and not interrupted and tostring(result):find("Terminated",1,true) then
            interrupted=true
            if type(context.onTerminate)=="function" then context.onTerminate() end
        end
        return ok,result
    end
    local function send(id,payload)
        if interrupted or not side or not rednet or type(rednet.send)~="function" then return false end
        local ok,result=network(rednet.send,id,payload,M.PROTOCOL)
        if not ok or result==false then side=nil;return false end
        return true
    end
    local function freshness()
        local t=clock()
        local at=latest and latest.matrix and latest.matrix.sampledAt
        local age=finite(at) and finite(t) and t>=at and t-at or nil
        -- Matrix telemetry remains useful when the optional reactor addon is
        -- absent or broken. Availability is a separate control prerequisite.
        return age,age~=nil and age<=2 and latest.error==nil
    end
    local function state(id)
        local peer=peers[id]
        if not peer or not latest then return end
        local age,fresh=freshness()
        send(id,{v=1,kind="state",clientSession=peer.clientSession,hostSession=hostSession,
            pairSession=peer.pairSession,seq=seq,controlEpoch=epoch,sourceAge=age,
            sourceFresh=fresh,snapshot=frozen(latest)})
    end
    function self.open()
        if interrupted then return false end
        if side and rednet and type(rednet.isOpen)=="function" then
            local ok,value=network(rednet.isOpen,side)
            if ok and value then return true end
            side=nil
        end
        local t=clock()
        if t<nextOpen then return false end
        nextOpen=t+1
        if not peripheral or not rednet or type(rednet.open)~="function" then return false end
        local ok,names=network(peripheral.getNames)
        if not ok or type(names)~="table" then return false end
        for _,name in ipairs(names) do
            if SIDES[name] then
                local wrapped,device=network(peripheral.wrap,name)
                if wrapped and type(device)=="table" and type(device.isWireless)=="function" then
                    local wireless,value=network(device.isWireless)
                    if wireless and value==true then
                        local opened,result=network(rednet.open,name)
                        if opened and result~=false and not interrupted then side=name;return true end
                    end
                end
            end
        end
        return false
    end
    function self.publish(snapshot)
        if type(snapshot)~="table" then return end
        latest=frozen(snapshot)
        seq=seq+1
        history[seq]={at=latest.matrix and latest.matrix.sampledAt}
        history[seq-16]=nil
        local reactor=latest.reactor or {}
        local parts={tostring(reactor.mode)}
        if reactor.mode=="PAUSE" or reactor.mode=="FAULT" then parts[#parts+1]=tostring(reactor.reason) end
        for i,action in ipairs(reactor.actions or {}) do
            if i>6 then break end
            parts[#parts+1]=tostring(action.id)..":"..tostring(action.enabled==true)
        end
        local key=table.concat(parts,"\31")
        if key~=signature then epoch=epoch+1;signature=key end
        for id in pairs(peers) do state(id) end
    end
    function self.capture(sender,payload,protocol)
        if interrupted or protocol~=M.PROTOCOL or not allowed[sender]
            or type(payload)~="table" or getmetatable(payload)~=nil
            or payload.v~=1 or not token(payload.clientSession) or not integer(payload.request) then return nil end
        if payload.kind~="hello" and payload.kind~="control" then return nil end
        if payload.kind=="control" and (not token(payload.hostSession) or not token(payload.pairSession)
            or not integer(payload.seq) or not integer(payload.controlEpoch) or not ACTIONS[payload.action]) then return nil end
        local peer=peers[sender]
        if peer and peer.clientSession==payload.clientSession and payload.request<=peer.lastRequest then return nil end
        local key=tostring(sender).."\31"..payload.clientSession.."\31"..payload.request
        -- Slots include expired tokens still queued in the owner's FIFO.
        -- Reclaiming on time alone would allow an unbounded FIFO while a
        -- peripheral call yields. Only owner consumption frees a slot.
        if pending[key] or count>=8 then return nil end
        -- Only copied scalars leave the capture coroutine; a later network
        -- event cannot mutate an already queued intent.
        local command={sender=sender,kind=payload.kind,clientSession=payload.clientSession,
            request=payload.request,hostSession=payload.hostSession,pairSession=payload.pairSession,
            seq=payload.seq,controlEpoch=payload.controlEpoch,action=payload.action,
            received=clock(),key=key}
        pending[key]=command;count=count+1
        return command
    end
    function self.process(command,applyAction)
        if type(command)~="table" or pending[command.key]~=command then return end
        pending[command.key]=nil;count=count-1
        local t=clock()
        if interrupted then return end
        local peer=peers[command.sender]
        local age=t-command.received
        if command.kind=="hello" then
            if not finite(age) or age<0 or age>2 then return end
            if not peer or peer.clientSession~=command.clientSession then
                peer={clientSession=command.clientSession,pairSession=unique("pair",clock),lastRequest=0}
                peers[command.sender]=peer
            end
            if command.request<=peer.lastRequest then return end
            peer.lastRequest=command.request
            send(command.sender,{v=1,kind="welcome",request=command.request,clientSession=peer.clientSession,
                hostSession=hostSession,pairSession=peer.pairSession})
            state(command.sender)
            return
        end
        local reason
        if not peer or peer.clientSession~=command.clientSession or command.hostSession~=hostSession
            or command.pairSession~=peer.pairSession then reason="Sitzung geaendert - neu verbinden"
        elseif command.request<=peer.lastRequest then return
        else
            peer.lastRequest=command.request
            local _,fresh=freshness()
            local reference=history[command.seq]
            if not finite(age) or age<0 or age>2 then reason="Befehl abgelaufen"
            elseif not fresh then reason="Messwerte veraltet"
            elseif latest.addonError~=nil or type(latest.reactor)~="table" then reason="Reaktor nicht verfuegbar"
            -- The owner refreshes protection before processing. That read may
            -- yield: validate the displayed source at receipt, independently
            -- of the current-source and queued-command age checks above.
            elseif not reference or not finite(reference.at) or command.received<reference.at
                or command.received-reference.at>2 then reason="Angezeigte Messwerte veraltet"
            elseif command.seq>seq or command.controlEpoch~=epoch then reason="Bedienzustand geaendert"
            else
                local enabled=false
                for _,a in ipairs(latest.reactor.actions or {}) do
                    if a.id==command.action and a.enabled==true then enabled=true end
                end
                if not enabled then reason="Aktion gesperrt" end
            end
        end
        local accepted=false
        if not reason then
            -- Do not catch owner callback failures: the main program owns its
            -- shutdown/error handling, including an interrupted peripheral call.
            local result,err=applyAction(command.action)
            accepted=result==true
            reason=accepted and "Verarbeitet - Zustand pruefen" or tostring(err or "Nicht angenommen")
        end
        send(command.sender,{v=1,kind="ack",request=command.request,clientSession=command.clientSession,
            hostSession=hostSession,pairSession=command.pairSession,accepted=accepted,reason=reason})
        state(command.sender)
    end
    return self
end
return M
