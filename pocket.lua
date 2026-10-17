-- Advanced Ender Pocket, CC:Tweaked. Host 4 owns every device and safety rule.
-- This program only displays cached host data and sends named button intents.
-- End/terminate/disconnect deliberately sends NO reactor command.
local PROTOCOL="matrix_remote_v1"
local DEFAULT_HOST=4
local args={...}
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function integer(v) return finite(v) and v>=1 and v<=2147483647 and v%1==0 end
local function validID(v) return finite(v) and v>=0 and v%1==0 and v<=2147483647 end
local function token(v) return type(v)=="string" and #v>0 and #v<=128 end
local function safeText(v) return tostring(v or "-"):gsub("[%c]"," ") end
local function tableOr(v) return type(v)=="table" and v or {} end
local function clock() return os.epoch and os.epoch("utc")/1000 or os.clock() end
local saved=settings and settings.get("matrix_remote.host")
local hostID=tonumber(args[1]) or (validID(saved) and saved or DEFAULT_HOST)
if args[1]=="setup" then print("Fester Computer: Host-ID?");hostID=tonumber(read()) end
if (args[1] and args[1]~="setup" and not tonumber(args[1])) or not validID(hostID) then
    print("Ungueltige Host-ID. Start: pocket 4");return
end
if settings then
    pcall(settings.set,"matrix_remote.host",hostID)
    pcall(settings.save)
end
local session="pocket:"..tostring(clock())..":"..tostring({}):gsub("table: ","")
local request,helloRequest,lastHello=0,nil,-math.huge
local hostSession,pairSession,lastSeq,lastState=nil,nil,0,nil
local data,sourceAge,sourceFresh=nil,nil,false
local page,note,pending="matrix","Verbinde mit Host "..hostID,nil
local modem,nextOpen=nil,-math.huge
local hits={}
local colors=colors
local sides={top=true,bottom=true,left=true,right=true,front=true,back=true}
local labels={auto="AUTO",pause="PAUSE",resume="WEITER",scram="NOT-AUS",reset="RESET",max_minus="MAX -",max_plus="MAX +"}
local function network(fn,...)
    local ok,result=pcall(fn,...)
    if not ok and tostring(result):find("Terminated",1,true) then error("Terminated",0) end
    return ok,result
end
local function open()
    if modem and rednet.isOpen then
        local ok,value=network(rednet.isOpen,modem)
        if ok and value then return true end
        modem=nil
    end
    local now=clock()
    if now<nextOpen then return false end
    nextOpen=now+1
    local ok,names=network(peripheral.getNames)
    if not ok or type(names)~="table" then return false end
    for _,side in ipairs(names) do
        if sides[side] then
            local wrapped,device=network(peripheral.wrap,side)
            if wrapped and type(device)=="table" and type(device.isWireless)=="function" then
                local checked,wireless=network(device.isWireless)
                if checked and wireless==true then
                    local opened,result=network(rednet.open,side)
                    if opened and result~=false then modem=side;return true end
                end
            end
        end
    end
    return false
end
local function send(payload)
    if not modem then return false end
    local ok,result=network(rednet.send,hostID,payload,PROTOCOL)
    if not ok or result==false then modem=nil;return false end
    return true
end
local function fresh()
    local age=lastState and clock()-lastState
    return modem~=nil and age~=nil and age>=0 and age<=3
        and sourceFresh and finite(sourceAge) and sourceAge+age<=2
end
local function fmt(n,unit,factor)
    if not finite(n) then return "-" end
    n=n*(factor or 1)
    local suffix={"","k","M","G","T","P","E"}
    local index=1
    while math.abs(n)>=1000 and index<#suffix do n=n/1000;index=index+1 end
    return string.format("%.2f %s%s",n,suffix[index],unit or "")
end
local function number(n,decimals)
    if not finite(n) then return "-" end
    return string.format("%."..(decimals or 1).."f",n)
end
local function percent(n) return finite(n) and number(n*100,0).."%" or "-" end
local function draw()
    local w,h=term.getSize()
    hits={}
    local function put(x,y,text,fg,bg,width)
        if x<1 or y<1 or x>w or y>h then return end
        local limit=math.min(width or w-x+1,w-x+1)
        if limit<=0 then return end
        text=safeText(text):sub(1,limit)
        term.setCursorPos(x,y);term.setTextColor(fg or colors.white);term.setBackgroundColor(bg or colors.black)
        term.write(text..string.rep(" ",limit-#text))
    end
    term.setBackgroundColor(colors.black);term.setTextColor(colors.white);term.clear();term.setCursorBlink(false)
    local split=math.max(1,math.floor(w/2))
    put(1,1," MATRIX",colors.white,page=="matrix" and colors.blue or colors.gray,split)
    put(split+1,1," REAKTOR",colors.white,page=="reactor" and colors.blue or colors.gray,w-split)
    local live=fresh()
    put(1,2,(live and "ONLINE" or "ALTE DATEN / OFFLINE").." H"..hostID,live and colors.lime or colors.orange)
    put(1,3,pending and "Warte auf Bestaetigung" or note,colors.yellow)
    local snapshot=tableOr(data)
    local m,r=tableOr(snapshot.matrix),tableOr(snapshot.reactor)
    if page=="matrix" then
        local factor=finite(snapshot.factor) and snapshot.factor>0 and snapshot.factor or 1
        local unit=snapshot.unit=="FE" and "FE" or "J"
        put(1,4,"MATRIX "..number(m.percent,1).."%",colors.cyan)
        local fill=finite(m.percent) and math.floor(math.max(0,math.min(100,m.percent))*w/100+.5) or 0
        put(1,5,string.rep(" ",fill),colors.white,live and colors.green or colors.gray,fill)
        put(fill+1,5,string.rep(" ",w-fill),colors.white,colors.gray,w-fill)
        put(1,6,"Gesp "..fmt(m.energy,unit,factor))
        put(1,7,"Kap  "..fmt(m.cap,unit,factor),colors.lightGray)
        put(1,8,"Ein  "..fmt(m.input,unit.."/t",factor),colors.lime)
        put(1,9,"Aus  "..fmt(m.output,unit.."/t",factor),colors.orange)
        local flowNet=m.flowNet
        if not finite(flowNet) and finite(m.input) and finite(m.output) then flowNet=m.input-m.output end
        put(1,10,"Net  "..fmt(flowNet,unit.."/t",factor),colors.cyan)
        put(1,11,"dE   "..fmt(m.net,unit.."/s",factor),colors.lightGray)
        put(1,12,m.status or "Keine Messwerte")
        put(1,13,"Rest "..safeText(m.eta))
        if snapshot.error then put(1,14,snapshot.error,colors.red) end
        put(1,h-1,"r / REAKTOR: Bedienung",colors.lightGray)
    else
        local buttonHeight=h>=17 and 2 or 1
        local top=math.max(4,h-3*buttonHeight)
        local function body(y,text,fg) if y<top then put(1,y,text,fg) end end
        local readings=tableOr(r.readings)
        body(4,"FISSION "..safeText(r.mode),r.mode=="FAULT" and colors.red or colors.cyan)
        body(5,snapshot.addonError or r.reason or "Keine Reaktordaten",colors.lightGray)
        body(6,"Ist "..number(readings.actual,2).." Soll "..number(readings.rate,2))
        body(7,"Max "..number(r.ceiling,2).." W "..number(r.coolingCeiling,2))
        body(8,"Temp "..number(readings.temperature,0).." K",colors.orange)
        body(9,"Wasser "..percent(readings.water).." Dampf "..percent(readings.steam))
        body(10,"Abf "..percent(readings.waste).." Brenn "..percent(readings.fuel))
        body(11,"Schaden "..number(readings.damage,0).."% "..safeText(r.calibration))
        body(12,r.stopError or r.notice or "m: Matrix / q: Ende",r.stopError and colors.red or colors.lightGray)
        body(13,(not live and "Bedienung gesperrt: offline") or "Nur farbige Tasten aktiv",colors.lightGray)
        local actions=tableOr(r.actions)
        local reactorAvailable=type(snapshot.reactor)=="table" and snapshot.addonError==nil
        for i=1,6 do
            local a=tableOr(actions[i])
            local action=labels[a.id] and a.id or nil
            local label=action and labels[action] or ({"AUTO","PAUSE","NOT-AUS","RESET","MAX -","MAX +"})[i]
            local col=(i-1)%2
            local x=col==0 and 1 or split+1
            local width=col==0 and split or w-split
            local y=top+math.floor((i-1)/2)*buttonHeight
            local enabled=live and reactorAvailable and not pending and a.enabled==true and action~=nil
            local bg=enabled and (action=="scram" and colors.red or colors.blue) or colors.gray
            for line=0,buttonHeight-1 do put(x,y+line,line==0 and " "..label or "",enabled and colors.white or colors.lightGray,bg,width) end
            if enabled and x<=w and y<=h and width>0 then
                hits[#hits+1]={x=x,y=y,w=width,h=math.min(buttonHeight,h-y+1),id=action}
            end
        end
    end
    put(1,h,"m:Matrix r:Reaktor q:Ende",colors.gray)
end
local function receive(sender,p,protocol)
    if sender~=hostID or protocol~=PROTOCOL or type(p)~="table" or getmetatable(p)~=nil
        or p.v~=1 or p.clientSession~=session then return end
    if p.kind=="welcome" then
        if p.request~=helloRequest or not token(p.hostSession) or not token(p.pairSession) then return end
        if p.hostSession~=hostSession or p.pairSession~=pairSession then
            hostSession,pairSession,lastSeq,lastState=p.hostSession,p.pairSession,0,nil
            pending=nil
        end
        note="Verbunden - warte auf Daten"
    elseif p.hostSession==hostSession and p.pairSession==pairSession and hostSession~=nil then
        if p.kind=="state" then
            if not integer(p.seq) or p.seq<=lastSeq or not integer(p.controlEpoch)
                or type(p.snapshot)~="table" then return end
            lastSeq,lastState,data=p.seq,clock(),p.snapshot
            sourceAge=finite(p.sourceAge) and p.sourceAge>=0 and p.sourceAge or nil
            sourceFresh=p.sourceFresh==true
            data.controlEpoch=p.controlEpoch
            if not pending and note=="Verbunden - warte auf Daten" then note="Werte vom festen Computer" end
        elseif p.kind=="ack" and pending and p.request==pending.request and type(p.accepted)=="boolean" then
            note=(p.accepted and "OK: " or "ABGELEHNT: ")..safeText(p.reason):sub(1,256)
            pending=nil
        end
    end
end
local function tick()
    local now=clock()
    if pending and now-pending.at>2 then pending=nil;note="Unbestaetigt - Zustand pruefen" end
    if open() and (not lastState or now-lastState>3) and now-lastHello>=1 then
        request=request+1;helloRequest=request;lastHello=now
        send({v=1,kind="hello",request=request,clientSession=session})
    elseif not modem then note="Ender-Modem fehlt / getrennt" end
end
local function click(x,y)
    if y==1 then page=x<=math.floor((term.getSize())/2) and "matrix" or "reactor";return end
    if not fresh() or pending then return end
    for _,hit in ipairs(hits) do
        if x>=hit.x and x<hit.x+hit.w and y>=hit.y and y<hit.y+hit.h then
            request=request+1
            local p={v=1,kind="control",clientSession=session,hostSession=hostSession,pairSession=pairSession,
                request=request,seq=lastSeq,controlEpoch=data.controlEpoch,action=hit.id}
            if send(p) then pending={request=request,at=clock()};note="Befehl gesendet"
            else note="Nicht gesendet - Funk pruefen" end
            return
        end
    end
end
local function run()
    tick();draw()
    local timer=os.startTimer(.25)
    while true do
        local event,a,b,c=os.pullEventRaw()
        if event=="terminate" or (event=="char" and a=="q") then return end
        if event=="char" then
            if a=="m" then page="matrix" elseif a=="r" then page="reactor" end
        elseif event=="mouse_click" and a==1 then click(b,c)
        elseif event=="rednet_message" then receive(a,b,c)
        elseif event=="timer" and a==timer then tick();timer=os.startTimer(.25)
        elseif event=="peripheral_detach" then if a==modem then modem=nil end
        elseif event=="peripheral" then nextOpen=-math.huge;tick() end
        draw()
    end
end
local ok,err=pcall(run)
term.setBackgroundColor(colors.black);term.setTextColor(colors.white);term.clear();term.setCursorPos(1,1)
if not ok and not tostring(err):find("Terminated",1,true) then printError(safeText(err)) end
print("Pocket beendet.")
