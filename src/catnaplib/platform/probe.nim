import os
import strformat
import math

when defined linux:
    import strutils
    import parsecfg
    import posix_utils
    from unicode import toLower

import times
import tables
import osproc
import re
from unicode import toLower
from "../global/definitions" import DistroId, PKGMANAGERS, PKGCOUNTCOMMANDS, toCachePath, toTmpPath
import "../terminal/logging"
import "caching"
import algorithm

proc getDistro*(): string =
    let cacheFile = "distroname".toCachePath
    result = readCache(cacheFile)
    if result != "": return

    when defined(linux):
    # Returns the name of the running linux distro
        result = "/etc/os-release".loadConfig.getSectionValue("", "PRETTY_NAME") & " " & uname().machine
    elif defined(macos):
        result = "MacOS X" & " " & uname().machine
    elif defined windows:
        result = "Windows"

    writeCache(cacheFile, result, INFINITEDURATION)

proc getDistroId*(): DistroId =
    let cacheFile = "distroid".toCachePath
    let raw = readCache(cacheFile)
    if raw != "":
        let raw_vals = raw.split(':')
        if raw_vals.len == 2:
            result.id = raw_vals[0]
            result.like = raw_vals[1]


    when defined linux:
        if fileExists("/boot/issue.txt"): # Check if raspbian else get distroid from /etc/os-release
            result.id = "raspbian"
            result.like = "debian"
        else:
            result.id = "/etc/os-release".loadConfig.getSectionValue("", "ID").toLower()
            result.like = "/etc/os-release".loadConfig.getSectionValue("", "ID_LIKE").toLower()

    when defined windows:
        result.id = "windows"
        result.like = "nt"

    writeCache(cacheFile, &"{result.id}|{result.like}", INFINITEDURATION)

proc getUptime*(): string =
    # Returns the system uptime as a string (DAYS, HOURS, MINUTES)

    # Uptime in sec
    when defined linux:
        let uptime = "/proc/uptime".open.readLine.split(".")[0]
    when defined windows:
        proc GetTickCount64(): cint {.importc, varargs, header: "sysinfoapi.h".}
        let uptime = int(GetTickCount64().float / 1000.float)

    let
        utu = uptime.parseUInt
        uth = utu div 3600 mod 24 # hours
        utm = utu mod 3600 div 60 # minutes
        utd = utu div 3600 div 24 # days

    if utd == 0 and uth != 0:
      result = &"{uth}h {utm}m" # return hours and mins
    elif uth == 0 and utd == 0:
      result = &"{utm}m" # return only mins
    else:
      result = &"{utd}d {uth}h {utm}m" # return days, hours and mins

proc getHostname*(): string =
    when defined linux:
        result = uname().nodename
    when defined windows:
        result = getEnv("COMPUTERNAME")

proc getUser*(): string =
    # Returns the current username
    when defined linux:
        result = getEnv("USER")
    when defined windows:
        result = getEnv("USERNAME")

proc getKernel*(): string =
    # Returns the active kernel version
    when defined linux:
        result = "/proc/version".open.readLine.split(" ")[2]
    when defined windows:
        result = "nt"

proc getParentPid(pid: int): int =
    let statusFilePath = "/proc/" & $pid & "/status"
    let statusLines = readFile(statusFilePath).split("\n")
    for rawline in statusLines:
        let stat = rawline.split(":")
        if stat[0] == "PPid": # Filter CurrentProcessInfo for Parent pid
            let pPid = parseInt(stat[1].strip())
            return pPid
    return -1

proc getProcessName(pid: int): string =
    let statusLines = readFile("/proc/" & $pid & "/status").split("\n")
    for rawLine in statusLines:
        let stat = rawLine.split(":")
        if stat[0] == "Name": # Filter ParentProcessInfo for Parent Name
            return stat[1].strip()

proc getTerminal*(): string =
    # Returns the currently running terminal emulator
    when defined linux:
        result = getCurrentProcessID().getParentPid().getParentPid().getProcessName()
        if result == "login" or result == "sshd":
            result = "tty"

    when defined windows:
        result = "PowerShell"

proc getShell*(): string =
    # Returns the system shell
    when defined linux:
        result = getCurrentProcessID().getParentPid().getProcessName()

    when defined windows:
        result = "PowerShell"

proc getDesktop*(): string =
    # Returns the running desktop env
    when defined windows:
        result = "Windows"
    when defined linux:
        result = getEnv("XDG_CURRENT_DESKTOP") # Check Current Desktop (Method 1)
    
        if result == "": # Check Current Desktop (Method 2)
            result = getEnv("XDG_SESSION_DESKTOP")
    
        if result == "": # Check Current Desktop (Method 3)
            result = getEnv("DESKTOP_SESSION")
    
        if result == "": # Check if in tty mode (Method 1)
            if getEnv("XDG_SESSION_TYPE") == "tty":
                result = "Headless"
    
        if result == "": # Check if in tty mode (Method 2)
            if getTerminal() == "tty":
                result = "Headless"
    
        if result == "": # Default to Unknown
            result = "Unknown"

proc getMemory*(mb: bool = true): string =
    # Returns statistics about the memory
    let 
        fileSeq: seq[string] = "/proc/meminfo".readLines(3)

        dividend: uint = if mb: 1000 else: 1024
        suffix: string = if mb: "MB" else: "MiB"

        memTotalString = fileSeq[0].split(" ")[^2]
        memAvailableString = fileSeq[2].split(" ")[^2]

        memTotalInt = memTotalString.parseUInt div dividend
        memAvailableInt = memAvailableString.parseUInt div dividend

        memUsedInt = memTotalInt - memAvailableInt
        percentage = ((int(memUsedInt) / int(memTotalInt)) * 100).round().int()

    result = &"{memUsedInt} / {memTotalInt} {suffix} ({percentage}%)"

proc getBattery*(): string =
    # Credits to https://gitlab.com/prashere/battinfo for regex implementation.
    
    let 
        BATTERY_REGEX = re"^BAT\d+$"
        powerPath = "/sys/class/power_supply/"

    var batterys: seq[tuple[idx: int, path: string]]

    # Collect all batterys
    for dir in os.walk_dir(powerPath):
      if re.match(os.last_path_part(dir.path), BATTERY_REGEX):
        batterys.add((parseInt($dir.path[^1]), dir.path & "/"))

    if batterys.len < 1:
        logError("No battery detected!")

    # Sort batterys by number
    sort(batterys)

    # Get stats for battery with lowest number  
    let
        batteryCapacity = readFile(batterys[0].path & "capacity").strip()
        batteryStatus = readFile(batterys[0].path & "status").strip()

    result = &"{batteryCapacity}% ({batteryStatus})"

proc getMounts*(): seq[string] =
    proc getMountPoints(): cstring {.importc, varargs, header: "getDisk.h".}

    let mounts_raw = $getMountPoints()
    if mounts_raw == "":
        logError("Failed to get disk mounting Points")

    let mounts = mounts_raw.split(',')

    for mount in mounts:
        if mount == "":
            continue
        
        if not mount.startsWith("/run/media"):
            if mount.startsWith("/proc") or
            mount.startsWith("/run")     or
            mount.startsWith("/sys")     or
            mount.startsWith("/tmp")     or
            mount.startsWith("/boot")    or
            mount.startsWith("/dev"):
                continue

        result.add(mount)

proc getDisk*(mount: string): string =
    # Returns diskinfo for the mounting point
    proc getTotalDiskSpace(mountingPoint: cstring): cfloat {.importc, varargs, header: "getDisk.h".}
    proc getUsedDiskSpace(mountingPoint: cstring): cfloat {.importc, varargs, header: "getDisk.h".}

    let
        total = getTotalDiskSpace(mount.cstring).round().int()
        used = getUsedDiskSpace(mount.cstring).round().int()
        percentage = ((used / total) * 100).round().int()
    result = &"{used} / {total} GB ({percentage}%)"

proc getCpu*(): string =
    # Returns the cpu name
    let cacheFile = "cpu".toCachePath
    result = readCache(cacheFile)
    if result != "":
        return

    let rawLines = readFile("/proc/cpuinfo").split("\n")
    
    var key_name = "model name"
    if getDistroId().id == "raspbian": key_name = "Model"

    for rawLine in rawLines:
        let line = rawLine.split(":")

        if line.len < 2: continue

        let
            key  = line[0].strip()
            val  = line[1].strip()
        if key == key_name: 
            result = val
            break
    
    writeCache(cacheFile, result, initDuration(days=1))

proc getPkgManager(distroId: DistroId): string =
    for key in PKGMANAGERS.keys:
        if distroId.id == key:
            return PKGMANAGERS[key]

    for key in PKGMANAGERS.keys:
        if distroId.like == key:
            return PKGMANAGERS[key]
    
    return "Unknown"

proc getPackages*(distroId: DistroId = getDistroId()): string =
    # Returns the installed package count
    let cacheFile = "packages".toCachePath

    result = readCache(cacheFile)
    if result != "":
        return

    let pkgManager = getPkgManager(distroId)
    if pkgManager == "Unknown":
        return "Unknown"

    var foundPkgCmd = false
    for key in PKGCOUNTCOMMANDS.keys:
        if pkgManager == key:
            foundPkgCmd = true
            break
    if not foundPkgCmd:
        return "Unknown"

    let tmpFile = "packages.txt".toTmpPath
    let cmd: string = PKGCOUNTCOMMANDS[pkgManager] & " > " & tmpFile
    if execCmd(cmd) != 0:
        logError("Failed to fetch pkg count!")
        
    let count = readFile(tmpFile).strip()
    result = count & " [" & pkgManager & "]"
    writeCache(cacheFile, result, initDuration(hours=2))

proc getGpu*(): string =
    # Returns the gpu name
    let cacheFile = "gpu".toCachePath

    result = readCache(cacheFile)
    if result != "":
        return

    let tmpFile = "lspci.txt".toTmpPath

    if execCmd("lspci > " & tmpFile) != 0:
        logError("Failed to fetch GPU!")

    var vga = "Unknown"
    let lspci = readFile(tmpFile)
    for line in lspci.split('\n'):
        if line.split(' ')[1] == "VGA":
            vga = line
            break

    let vga_parts = vga.split(":")

    if vga_parts.len >= 2 or vga != "Unknown":
        result = vga_parts[vga_parts.len - 1].split("(")[0].strip()
    else:
        result = "Unknown"
        
    writeCache(cacheFile, result, initDuration(days=1))

proc getWeather*(): string =
    # Returns current weather
    let cacheFile = "weather".toCachePath

    result = readCache(cacheFile)
    if result != "":
        return

    let tmpFile = "weather.txt".toTmpPath
    if execCmd("curl -s wttr.in/?format=3 > " & tmpFile) != 0:
        logError("Failed to fetch weather!")
    
    result = readFile(tmpFile).strip()
    writeCache(cacheFile, result, initDuration(minutes=20))
