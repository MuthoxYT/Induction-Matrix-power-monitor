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
-- Terminal-local theme and buffered drawing keep the Pocket calm and readable.
local THEME={
    [colors.black]=0x080D14,[colors.gray]=0x142130,[colors.blue]=0x1B3046,
    [colors.white]=0xE9F1F6,[colors.lightGray]=0x91A6B9,[colors.cyan]=0x58D1DC,
    [colors.green]=0x35B78C,[colors.lime]=0x7DE2BB,[colors.orange]=0xEFB366,
    [colors.red]=0xED7483,[colors.yellow]=0xEFB366,
}
local originalPalette,themeApplied={},false
local previousRows,previousWidth,previousHeight
local seenNote,seenNoteAt=nil,0
local function theme()
    if themeApplied then return end
    themeApplied=true
    if type(term.setPaletteColor)~="function" then return end
    for color,value in pairs(THEME) do
        if type(term.getPaletteColor)=="function" then
            local ok,r,g,b=pcall(term.getPaletteColor,color)
            if ok then originalPalette[color]={r,g,b} end
        end
        pcall(term.setPaletteColor,color,value)
    end
end
local function restorePalette()
    for color,rgb in pairs(originalPalette) do pcall(term.setPaletteColor,color,table.unpack(rgb)) end
end
local function code(c)
    local n=0;while c>1 do c=c/2;n=n+1 end
    return ("0123456789abcdef"):sub(n+1,n+1)
end
local FONT={
    ['0']={'111','101','101','101','111'},['1']={'010','110','010','010','111'},
    ['2']={'111','001','111','100','111'},['3']={'111','001','111','001','111'},
    ['4']={'101','101','111','001','001'},['5']={'111','100','111','001','111'},
    ['6']={'111','100','111','101','111'},['7']={'111','001','010','010','010'},
    ['8']={'111','101','111','101','111'},['9']={'111','101','111','001','111'},
    ['.']={'000','000','000','000','010'},['%']={'101','001','010','100','101'},
}
local function draw()
    theme()
    local w,h=term.getSize()
    local rows={}
    for y=1,h do rows[y]={string.rep(' ',w),string.rep(code(colors.white),w),string.rep(code(colors.black),w)} end
    hits={}
    local function put(x,y,text,fg,bg,width)
        if x<1 or y<1 or x>w or y>h then return end
        local limit=math.min(width or w-x+1,w-x+1)
        if limit<=0 then return end
        text=safeText(text):sub(1,limit);text=text..string.rep(' ',limit-#text)
        local values={text,string.rep(code(fg or colors.white),limit),string.rep(code(bg or colors.black),limit)}
        for i=1,3 do rows[y][i]=rows[y][i]:sub(1,x-1)..values[i]..rows[y][i]:sub(x+limit) end
    end
    local function rect(x,y,width,height,bg)
        for row=y,y+height-1 do put(x,row,'',colors.white,bg,width) end
    end
    local function center(y,text,fg,bg,x,span)
        x,span=x or 1,span or w
        text=safeText(text):sub(1,math.max(0,span))
        put(x+math.max(0,math.floor((span-#text)/2)),y,text,fg,bg,#text)
    end
    local function field(y,label,value,fg,bg)
        if y<3 or y>=h then return end
        rect(2,y,w-2,1,bg or colors.black)
        label,value=safeText(label),safeText(value)
        local available=math.max(1,w-#label-4)
        value=value:sub(1,available)
        put(2,y,label,colors.lightGray,bg,#label)
        put(math.max(2+#label+1,w-#value),y,value,fg,bg,#value)
    end
    local function wrap(y,message,count,fg,bg)
        local width=math.max(1,w-2)
        local lines,line={},''
        for word in safeText(message):gmatch('%S+') do
            if #line>0 and #line+#word+1>width then lines[#lines+1]=line;line='' end
            while #word>width do
                if #line>0 then lines[#lines+1]=line;line='' end
                lines[#lines+1]=word:sub(1,width);word=word:sub(width+1)
            end
            if #word>0 then line=#line>0 and line..' '..word or word end
        end
        if #line>0 then lines[#lines+1]=line end
        for i=1,math.min(count,#lines) do
            local text=lines[i]
            if i==count and #lines>count and width>=3 then text=text:sub(1,width-3)..'...' end
            put(2,y+i-1,text,fg,bg,width)
        end
    end
    local live=fresh()
    local snapshot=tableOr(data)
    local m,r=tableOr(snapshot.matrix),tableOr(snapshot.reactor)
    local split=math.max(1,math.floor(w/2))
    rect(1,1,split,1,page=='matrix' and colors.blue or colors.gray)
    rect(split+1,1,w-split,1,page=='reactor' and colors.blue or colors.gray)
    center(1,'MATRIX',page=='matrix' and colors.cyan or colors.lightGray,page=='matrix' and colors.blue or colors.gray,1,split)
    center(1,'REAKTOR',page=='reactor' and colors.cyan or colors.lightGray,page=='reactor' and colors.blue or colors.gray,split+1,w-split)
    put(2,2,(live and 'ONLINE H' or (data and 'ALTE DATEN H' or 'OFFLINE H'))..hostID,live and colors.lime or colors.orange,nil,math.max(1,w-7))
    put(math.max(1,w-3),2,'5s',colors.lightGray,nil,math.min(3,w))
    local alert
    local alertTone=colors.orange
    if note~=seenNote then seenNote,seenNoteAt=note,clock() end
    if pending then alert='Warte auf Bestaetigung'
    elseif note:find('ABGELEHNT:',1,true)==1 then alert=note:gsub('^ABGELEHNT:%s*','Abgelehnt: ')
    elseif note:find('Unbestaetigt',1,true)==1 or note:find('Nicht gesendet',1,true)==1 then alert=note
    elseif note:find('OK:',1,true)==1 and clock()-seenNoteAt<=4 then alert,alertTone=note,colors.lime end
    local function message(y,count,text,tone)
        if text then wrap(y,text,count,tone or colors.orange,colors.gray) end
    end
    if page=='matrix' then
        local factor=finite(snapshot.factor) and snapshot.factor>0 and snapshot.factor or 1
        local unit=snapshot.unit=='FE' and 'FE' or 'J'
        local pct=number(m.percent,1)..'%'
        if finite(m.percent) and m.percent<100 and pct=='100.0%' then pct='99.9%' end
        local fillColor=finite(m.percent) and (m.percent<=20 and colors.red or (m.percent<=50 and colors.orange or colors.cyan)) or colors.gray
        local roomy=w>=24 and h>=20
        local storageY,flowY,forecastY=roomy and 10 or 6,roomy and 12 or 8,roomy and 16 or 12
        if roomy then
            rect(2,3,w-2,7,colors.gray)
            put(3,3,'SPEICHER',colors.lightGray,colors.gray,8)
            put(w-#pct-1,3,pct,fillColor,colors.gray,#pct)
            local big=pct:gsub('%.0%%','%%')
            if #big*4-1<=w-4 then
                local start=math.floor((w-(#big*4-1))/2)+1
                for i=1,#big do
                    local glyph=FONT[big:sub(i,i)]
                    if glyph then for gy=1,5 do for gx=1,3 do
                        if glyph[gy]:sub(gx,gx)=='1' then rect(start+(i-1)*4+gx-1,gy+3,1,1,colors.white) end
                    end end end
                end
            else center(6,pct,colors.white,colors.gray) end
        else
            put(2,3,'SPEICHER '..pct,fillColor)
        end
        local barY=roomy and 9 or 4
        local inner=math.max(0,w-4)
        local fill=finite(m.percent) and math.floor(math.max(0,math.min(100,m.percent))*inner/100+.5) or 0
        rect(3,barY,inner,1,colors.blue);rect(3,barY,fill,1,live and fillColor or colors.gray)
        field(storageY,'Gesp',fmt(m.energy,unit,factor),colors.white)
        field(storageY+1,'Kap',fmt(m.cap,unit,factor),colors.lightGray)
        field(flowY,'Ein',fmt(m.input,unit..'/t',factor),colors.lime,colors.gray)
        field(flowY+1,'Aus',fmt(m.output,unit..'/t',factor),colors.orange,colors.gray)
        local net=m.flowNet
        if not finite(net) and finite(m.input) and finite(m.output) then net=m.input-m.output end
        local sign=finite(net) and net>0 and '+' or ''
        field(flowY+2,'Net',sign..fmt(net,unit..'/t',factor),finite(net) and net<0 and colors.orange or colors.lime,colors.gray)
        field(flowY+3,'Trend',fmt(m.net,unit..'/s',factor),colors.lightGray)
        if forecastY<h then
            rect(2,forecastY,w-2,2,colors.blue)
            center(forecastY,m.status or 'WARTE AUF DATEN',m.status=='ENTLAEDT' and colors.orange or colors.lime,colors.blue,2,w-2)
            center(forecastY+1,safeText(m.eta):gsub(' in ca%. ',' in '),colors.white,colors.blue,2,w-2)
        end
        message(forecastY+2,math.max(0,h-forecastY-2),snapshot.error or alert,snapshot.error and colors.red or alertTone)
    else
        local buttonHeight=h>=17 and 2 or 1
        local top=math.max(4,h-3*buttonHeight)
        local statusTop=math.max(4,math.min(12,top-2))
        local readings=tableOr(r.readings)
        local function body(y,text,fg,bg) if y<statusTop then put(2,y,text,fg,bg,w-2) end end
        local function card(y,label,value,fg,bg) if y<statusTop then field(y,label,value,fg,bg) end end
        if 3<top then
            rect(2,3,w-2,1,colors.gray)
            put(3,3,'FISSION',colors.lightGray,colors.gray,7)
            local mode=safeText(r.mode)
            put(math.max(3,w-#mode-1),3,mode,r.mode=='FAULT' and colors.red or colors.cyan,colors.gray,#mode)
        end
        card(4,'IST / SOLL','mB/t',colors.lightGray)
        if 5<statusTop then
            rect(2,5,w-2,1,colors.blue)
            center(5,number(readings.actual,2)..' / '..number(readings.rate,2),colors.white,colors.blue,2,w-2)
        end
        body(6,'Max '..number(r.ceiling,2)..'  Wasser '..number(r.coolingCeiling,1),colors.lightGray)
        body(7,'Temp '..number(readings.temperature,0)..'K Schaden '..number(readings.damage,0)..'%',finite(readings.damage) and readings.damage>0 and colors.red or colors.white)
        if 8<statusTop then
            local half=math.max(1,math.floor((w-3)/2))
            center(8,'WASSER '..percent(readings.water),colors.cyan,nil,2,half)
            center(8,'DAMPF '..percent(readings.steam),colors.orange,nil,half+3,w-half-3)
            local function tank(x,span,value,color)
                if 9>=statusTop then return end
                local n=finite(value) and math.floor(math.max(0,math.min(1,value))*span+.5) or 0
                rect(x,9,span,1,colors.gray);rect(x,9,n,1,color)
            end
            tank(2,half,readings.water,colors.cyan)
            tank(half+3,w-half-3,readings.steam,colors.orange)
        end
        body(10,'Abfall '..percent(readings.waste)..'  Brenn '..percent(readings.fuel),colors.lightGray)
        body(11,'Kalibriert: '..safeText(r.calibration),colors.cyan)
        local status=r.stopError or snapshot.addonError or (r.mode=='FAULT' and r.reason)
            or alert or r.notice or r.reason
        local tone=(r.stopError or snapshot.addonError or r.mode=='FAULT') and colors.red
            or (alert and alertTone or colors.lightGray)
        message(statusTop,math.max(0,math.min(2,top-statusTop)),status,tone)
        local actions=tableOr(r.actions)
        local available=type(snapshot.reactor)=='table' and snapshot.addonError==nil
        for i=1,6 do
            local a=tableOr(actions[i])
            local id=labels[a.id] and a.id or nil
            local label=id and labels[id] or ({'AUTO','PAUSE','NOT-AUS','RESET','MAX -','MAX +'})[i]
            local col=(i-1)%2
            local x=col==0 and 2 or split+2
            local span=col==0 and split-2 or w-split-2
            local y=top+math.floor((i-1)/2)*buttonHeight
            local enabled=live and available and not pending and a.enabled==true and id~=nil
            local bg=enabled and (id=='scram' and colors.red or colors.blue) or colors.gray
            local fg=enabled and (id=='scram' and colors.black or colors.white) or colors.lightGray
            rect(x,y,span,buttonHeight,bg)
            center(y,label,fg,bg,x,span)
            if buttonHeight>1 then center(y+1,enabled and 'bereit' or (not live and 'offline' or (pending and 'wartet' or 'gesperrt')),fg,bg,x,span) end
            if enabled and x<=w and y<=h and span>0 then hits[#hits+1]={x=x,y=y,w=span,h=math.min(buttonHeight,h-y+1),id=id} end
        end
    end
    put(1,h,'m MATRIX r REAKTOR q ENDE',colors.lightGray,colors.gray,w)
    if previousWidth~=w or previousHeight~=h then previousRows=nil end
    term.setCursorBlink(false)
    for y,row in ipairs(rows) do
        local old=previousRows and previousRows[y]
        if not old or row[1]~=old[1] or row[2]~=old[2] or row[3]~=old[3] then
            if type(term.blit)=='function' then
                term.setCursorPos(1,y);term.blit(row[1],row[2],row[3])
            else
                local x=1
                while x<=w do
                    local last=x
                    while last<w and row[2]:sub(last+1,last+1)==row[2]:sub(x,x) and row[3]:sub(last+1,last+1)==row[3]:sub(x,x) do last=last+1 end
                    term.setCursorPos(x,y)
                    term.setTextColor(2^tonumber(row[2]:sub(x,x),16));term.setBackgroundColor(2^tonumber(row[3]:sub(x,x),16))
                    term.write(row[1]:sub(x,last));x=last+1
                end
            end
        end
    end
    previousRows,previousWidth,previousHeight=rows,w,h
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
restorePalette()
term.setBackgroundColor(colors.black);term.setTextColor(colors.white);term.clear();term.setCursorPos(1,1)
if not ok and not tostring(err):find("Terminated",1,true) then printError(safeText(err)) end
print("Pocket beendet.")
