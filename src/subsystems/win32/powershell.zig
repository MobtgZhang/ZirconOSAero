//! PowerShell - Advanced Command Shell
//! Object-oriented command shell with cmdlet-based architecture.
//! Supports cmdlets: Get-Process, Get-ChildItem, Get-Date, Get-Help,
//! Set-Location, Write-Output, Clear-Host, Get-Service, etc.

const console = @import("console.zig");
const diskpart = @import("diskpart.zig");
const vfs = @import("../../fs/vfs.zig");
const fat32 = @import("../../fs/fat32.zig");
const ntfs = @import("../../fs/ntfs.zig");
const process = @import("../../ps/process.zig");
const scheduler = @import("../../ke/scheduler.zig");
const klog = @import("../../rtl/klog.zig");

pub const PS_VERSION = "ZirconOS PowerShell";
pub const PS_VERSION_FULL = "ZirconOS PowerShell 1.0.0";
pub const PS_COPYRIGHT = "Copyright (c) ZirconOS Project. All rights reserved.";

const MAX_CMD_LEN: usize = 512;
const MAX_HISTORY: usize = 64;
const MAX_VARIABLES: usize = 128;
const MAX_ALIASES: usize = 64;

pub const ShellState = enum {
    idle,
    running,
    executing,
    pipeline,
    exiting,
};

pub const PsVariable = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    value: [256]u8 = [_]u8{0} ** 256,
    value_len: usize = 0,
    is_readonly: bool = false,
    is_automatic: bool = false,
};

pub const PsAlias = struct {
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    definition: [64]u8 = [_]u8{0} ** 64,
    definition_len: usize = 0,
};

pub const PowerShell = struct {
    state: ShellState = .idle,
    current_dir: [260]u8 = [_]u8{0} ** 260,
    current_dir_len: usize = 0,
    history: [MAX_HISTORY][MAX_CMD_LEN]u8 = [_][MAX_CMD_LEN]u8{[_]u8{0} ** MAX_CMD_LEN} ** MAX_HISTORY,
    history_len: [MAX_HISTORY]usize = [_]usize{0} ** MAX_HISTORY,
    history_count: usize = 0,
    variables: [MAX_VARIABLES]PsVariable = [_]PsVariable{.{}} ** MAX_VARIABLES,
    var_count: usize = 0,
    aliases: [MAX_ALIASES]PsAlias = [_]PsAlias{.{}} ** MAX_ALIASES,
    alias_count: usize = 0,
    console_id: u32 = 0,
    exit_code: i32 = 0,
    prompt_depth: u32 = 0,
    error_count: u32 = 0,

    pub fn init(self: *PowerShell) void {
        self.state = .running;
        const dir = "C:\\";
        @memcpy(self.current_dir[0..dir.len], dir);
        self.current_dir_len = dir.len;

        self.setVariable("PSVersionTable", PS_VERSION_FULL, true, true);
        self.setVariable("PSEdition", "Core", true, true);
        self.setVariable("Host", "ZirconOS PowerShell Host", true, true);
        self.setVariable("HOME", "C:\\Users\\System", false, true);
        self.setVariable("PROFILE", "C:\\Users\\System\\profile.ps1", false, true);
        self.setVariable("PSModulePath", "C:\\ZirconOS\\System32\\ZShell\\Modules", false, true);
        self.setVariable("true", "True", true, true);
        self.setVariable("false", "False", true, true);
        self.setVariable("null", "", true, true);
        self.setVariable("ErrorActionPreference", "Continue", false, false);
        self.setVariable("ConfirmPreference", "High", false, false);
        self.setVariable("LASTEXITCODE", "0", false, true);

        self.addAlias("ls", "Get-ChildItem");
        self.addAlias("dir", "Get-ChildItem");
        self.addAlias("cd", "Set-Location");
        self.addAlias("pwd", "Get-Location");
        self.addAlias("cat", "Get-Content");
        self.addAlias("echo", "Write-Output");
        self.addAlias("cls", "Clear-Host");
        self.addAlias("rm", "Remove-Item");
        self.addAlias("cp", "Copy-Item");
        self.addAlias("mv", "Move-Item");
        self.addAlias("ps", "Get-Process");
        self.addAlias("man", "Get-Help");
        self.addAlias("kill", "Stop-Process");
        self.addAlias("where", "Where-Object");
        self.addAlias("select", "Select-Object");
        self.addAlias("sort", "Sort-Object");
        self.addAlias("measure", "Measure-Object");
        self.addAlias("foreach", "ForEach-Object");
        self.addAlias("type", "Get-Content");
        self.addAlias("gi", "Get-Item");
        self.addAlias("gci", "Get-ChildItem");
        self.addAlias("sl", "Set-Location");
        self.addAlias("gl", "Get-Location");
        self.addAlias("gps", "Get-Process");
    }

    pub fn setVariable(self: *PowerShell, name: []const u8, value: []const u8, is_readonly: bool, is_auto: bool) void {
        for (self.variables[0..self.var_count]) |*v| {
            if (strEqlI(v.name[0..v.name_len], name)) {
                if (v.is_readonly) return;
                const v_copy = @min(value.len, v.value.len);
                @memcpy(v.value[0..v_copy], value[0..v_copy]);
                v.value_len = v_copy;
                return;
            }
        }
        if (self.var_count >= MAX_VARIABLES) return;
        var v = &self.variables[self.var_count];
        const n_copy = @min(name.len, v.name.len);
        @memcpy(v.name[0..n_copy], name[0..n_copy]);
        v.name_len = n_copy;
        const val_copy = @min(value.len, v.value.len);
        @memcpy(v.value[0..val_copy], value[0..val_copy]);
        v.value_len = val_copy;
        v.is_readonly = is_readonly;
        v.is_automatic = is_auto;
        self.var_count += 1;
    }

    pub fn getVariable(self: *PowerShell, name: []const u8) ?[]const u8 {
        for (self.variables[0..self.var_count]) |*v| {
            if (strEqlI(v.name[0..v.name_len], name)) {
                return v.value[0..v.value_len];
            }
        }
        return null;
    }

    fn addAlias(self: *PowerShell, name: []const u8, definition: []const u8) void {
        if (self.alias_count >= MAX_ALIASES) return;
        var a = &self.aliases[self.alias_count];
        const n_copy = @min(name.len, a.name.len);
        @memcpy(a.name[0..n_copy], name[0..n_copy]);
        a.name_len = n_copy;
        const d_copy = @min(definition.len, a.definition.len);
        @memcpy(a.definition[0..d_copy], definition[0..d_copy]);
        a.definition_len = d_copy;
        self.alias_count += 1;
    }

    fn resolveAlias(self: *PowerShell, name: []const u8) ?[]const u8 {
        for (self.aliases[0..self.alias_count]) |*a| {
            if (strEqlI(a.name[0..a.name_len], name)) {
                return a.definition[0..a.definition_len];
            }
        }
        return null;
    }

    pub fn showBanner(self: *PowerShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine(PS_VERSION_FULL);
        con.writeLine(PS_COPYRIGHT);
        con.writeLine("");
        con.writeLine("Type 'Get-Help' for help information.");
        con.writeLine("");
    }

    pub fn showPrompt(self: *PowerShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = con.writeOutput("PS ");
        _ = con.writeOutput(self.current_dir[0..self.current_dir_len]);
        _ = con.writeOutput("> ");
    }

    pub fn executeCommand(self: *PowerShell, input: []const u8) void {
        if (input.len == 0) return;
        self.addHistory(input);
        self.state = .executing;

        const trimmed = trim(input);
        if (trimmed.len == 0) {
            self.state = .running;
            return;
        }

        var cmd_name_end: usize = 0;
        while (cmd_name_end < trimmed.len and trimmed[cmd_name_end] != ' ') {
            cmd_name_end += 1;
        }

        var cmd_name = trimmed[0..cmd_name_end];
        const args_start = if (cmd_name_end < trimmed.len) cmd_name_end + 1 else trimmed.len;
        const args = trimmed[args_start..];

        if (self.resolveAlias(cmd_name)) |resolved| {
            cmd_name = resolved;
        }

        if (strEqlI(cmd_name, "Get-ChildItem")) {
            self.cmdGetChildItem(args);
        } else if (strEqlI(cmd_name, "Set-Location")) {
            self.cmdSetLocation(args);
        } else if (strEqlI(cmd_name, "Get-Location")) {
            self.cmdGetLocation();
        } else if (strEqlI(cmd_name, "Get-Process")) {
            self.cmdGetProcess();
        } else if (strEqlI(cmd_name, "Get-Date")) {
            self.cmdGetDate();
        } else if (strEqlI(cmd_name, "Get-Help")) {
            self.cmdGetHelp(args);
        } else if (strEqlI(cmd_name, "Write-Output")) {
            self.cmdWriteOutput(args);
        } else if (strEqlI(cmd_name, "Write-Host")) {
            self.cmdWriteHost(args);
        } else if (strEqlI(cmd_name, "Clear-Host")) {
            self.cmdClearHost();
        } else if (strEqlI(cmd_name, "Get-Service")) {
            self.cmdGetService();
        } else if (strEqlI(cmd_name, "Get-Command")) {
            self.cmdGetCommand();
        } else if (strEqlI(cmd_name, "Get-Alias")) {
            self.cmdGetAlias();
        } else if (strEqlI(cmd_name, "Get-Variable")) {
            self.cmdGetVariable(args);
        } else if (strEqlI(cmd_name, "Set-Variable")) {
            self.cmdSetVariable(args);
        } else if (strEqlI(cmd_name, "Get-History")) {
            self.cmdGetHistory();
        } else if (strEqlI(cmd_name, "Get-Host")) {
            self.cmdGetHost();
        } else if (strEqlI(cmd_name, "Get-Content")) {
            self.cmdGetContent(args);
        } else if (strEqlI(cmd_name, "New-Item")) {
            self.cmdNewItem(args);
        } else if (strEqlI(cmd_name, "Remove-Item")) {
            self.cmdRemoveItem(args);
        } else if (strEqlI(cmd_name, "Test-Path")) {
            self.cmdTestPath(args);
        } else if (strEqlI(cmd_name, "Stop-Computer")) {
            self.cmdStopComputer(args);
        } else if (strEqlI(cmd_name, "Restart-Computer")) {
            self.cmdRestartComputer(args);
        } else if (strEqlI(cmd_name, "shutdown") or strEqlI(cmd_name, "shutdown.exe")) {
            self.cmdShutdownExe(args);
        } else if (strEqlI(cmd_name, "diskpart") or strEqlI(cmd_name, "diskpart.exe")) {
            self.cmdDiskpart();
        } else if (strEqlI(cmd_name, "Get-Disk")) {
            self.cmdGetDisk();
        } else if (strEqlI(cmd_name, "Get-Partition")) {
            self.cmdGetPartition();
        } else if (strEqlI(cmd_name, "Get-Volume")) {
            self.cmdGetVolume();
        } else if (strEqlI(cmd_name, "Exit") or strEqlI(cmd_name, "exit")) {
            self.state = .exiting;
            return;
        } else if (cmd_name.len > 0) {
            const con = console.getConsole(self.console_id) orelse return;
            _ = con.writeOutput(cmd_name);
            con.writeLine(": The term is not recognized as a cmdlet, function, or operable program.");
            self.error_count += 1;
        }

        self.state = .running;
    }

    fn cmdGetChildItem(self: *PowerShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine("    Directory: " ++ "C:\\");
        con.writeLine("");
        con.writeLine("Mode                 LastWriteTime         Length Name");
        con.writeLine("----                 -------------         ------ ----");

        const vol = fat32.getVolume();
        for (vol.root_entries[0..vol.root_entry_count]) |*entry| {
            if (entry.isFree() or entry.isVolumeId()) continue;

            if (entry.isDirectory()) {
                _ = con.writeOutput("d-----       ");
            } else {
                _ = con.writeOutput("-a----       ");
            }
            _ = con.writeOutput("2024/01/01  00:00    ");

            if (!entry.isDirectory()) {
                var size_buf: [16]u8 = undefined;
                _ = con.writeOutput(formatUint(&size_buf, entry.file_size));
            }
            _ = con.writeOutput("  ");

            var name_buf: [12]u8 = undefined;
            var pos: usize = 0;
            for (entry.name) |c| {
                if (c == ' ') break;
                if (pos < name_buf.len) {
                    name_buf[pos] = c;
                    pos += 1;
                }
            }
            con.writeLine(name_buf[0..pos]);
        }
        con.writeLine("");
    }

    fn cmdSetLocation(self: *PowerShell, args: []const u8) void {
        const trimmed = trim(args);
        if (trimmed.len == 0) return;
        if (trimmed.len == 2 and trimmed[0] == '.' and trimmed[1] == '.') {
            if (self.current_dir_len > 3) {
                var i = self.current_dir_len - 1;
                if (i > 0 and self.current_dir[i - 1] == '\\') i -= 1;
                while (i > 2 and self.current_dir[i - 1] != '\\') i -= 1;
                self.current_dir_len = i;
            }
            return;
        }
        if (trimmed.len < 260) {
            const copy_len = @min(trimmed.len, self.current_dir.len - self.current_dir_len - 1);
            if (self.current_dir_len > 0 and self.current_dir[self.current_dir_len - 1] != '\\') {
                self.current_dir[self.current_dir_len] = '\\';
                self.current_dir_len += 1;
            }
            @memcpy(self.current_dir[self.current_dir_len..][0..copy_len], trimmed[0..copy_len]);
            self.current_dir_len += copy_len;
        }
    }

    fn cmdGetLocation(self: *PowerShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine("Path");
        con.writeLine("----");
        con.writeLine(self.current_dir[0..self.current_dir_len]);
        con.writeLine("");
    }

    fn cmdGetProcess(self: *PowerShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine(" NPM(K)  PM(K)  WS(K)  CPU(s)    Id  SI ProcessName");
        con.writeLine(" ------  -----  -----  ------    --  -- -----------");
        con.writeLine("      0      0      0    0.00     1   0 System");
        con.writeLine("      0      0      0    0.00     2   0 smss");
        con.writeLine("      0      0      0    0.00     3   0 csrss");
        con.writeLine("      0      0      0    0.00     4   0 powershell");
        con.writeLine("");
    }

    fn cmdGetDate(self: *PowerShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine("Monday, January 1, 2024 00:00:00");
        con.writeLine("");
    }

    fn cmdGetHelp(self: *PowerShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine("TOPIC");
        con.writeLine("    ZirconOS PowerShell Help System");
        con.writeLine("");
        con.writeLine("AVAILABLE CMDLETS:");
        con.writeLine("  Get-ChildItem    - Lists files and directories (alias: ls, dir, gci)");
        con.writeLine("  Set-Location     - Changes the current directory (alias: cd, sl)");
        con.writeLine("  Get-Location     - Gets the current directory (alias: pwd, gl)");
        con.writeLine("  Get-Process      - Gets running processes (alias: ps, gps)");
        con.writeLine("  Get-Date         - Gets the current date and time");
        con.writeLine("  Get-Help         - Displays help information (alias: man)");
        con.writeLine("  Write-Output     - Sends output to the pipeline (alias: echo)");
        con.writeLine("  Write-Host       - Writes to the console");
        con.writeLine("  Clear-Host       - Clears the console (alias: cls)");
        con.writeLine("  Get-Service      - Gets system services");
        con.writeLine("  Get-Command      - Gets available commands");
        con.writeLine("  Get-Alias        - Gets defined aliases");
        con.writeLine("  Get-Variable     - Gets variables");
        con.writeLine("  Set-Variable     - Sets a variable value");
        con.writeLine("  Get-History      - Gets command history");
        con.writeLine("  Get-Host         - Gets the host information");
        con.writeLine("  Get-Content      - Gets file content (alias: cat, type)");
        con.writeLine("  New-Item         - Creates a new item");
        con.writeLine("  Remove-Item      - Removes an item (alias: rm)");
        con.writeLine("  Test-Path        - Tests if a path exists");
        con.writeLine("  Get-Disk         - Gets physical disk objects");
        con.writeLine("  Get-Partition    - Gets partition objects");
        con.writeLine("  Get-Volume       - Gets volume objects");
        con.writeLine("  Stop-Computer    - Shuts down the computer");
        con.writeLine("  Restart-Computer - Restarts the computer");
        con.writeLine("  shutdown         - Shuts down, restarts, or logs off (/s /r /h /l /a)");
        con.writeLine("  diskpart         - Opens the DiskPart utility");
        con.writeLine("  Exit             - Exits the shell");
        con.writeLine("");
    }

    fn cmdWriteOutput(self: *PowerShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine(args);
    }

    fn cmdWriteHost(self: *PowerShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine(args);
    }

    fn cmdClearHost(self: *PowerShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.clear();
    }

    fn cmdGetService(self: *PowerShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine("Status   Name               DisplayName");
        con.writeLine("------   ----               -----------");
        con.writeLine("Running  PsServer           Process Server");
        con.writeLine("Running  SmssServer          Session Manager");
        con.writeLine("Running  ObServer            Object Manager Service");
        con.writeLine("Running  IoServer            I/O Manager Service");
        con.writeLine("Running  LpcServer           LPC Port Service");
        con.writeLine("Running  VfsServer           Virtual File System");
        con.writeLine("Running  ConHost             Console Host");
        con.writeLine("");
    }

    fn cmdGetCommand(self: *PowerShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine("CommandType     Name                          Version    Source");
        con.writeLine("-----------     ----                          -------    ------");
        con.writeLine("Cmdlet          Clear-Host                    7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Get-Alias                     7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Get-ChildItem                 7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Get-Command                   7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Get-Content                   7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Get-Date                      7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Get-Disk                      7.4.0      ZirconOS.Storage");
        con.writeLine("Cmdlet          Get-Help                      7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Get-History                   7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Get-Host                      7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Get-Location                  7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Get-Partition                 7.4.0      ZirconOS.Storage");
        con.writeLine("Cmdlet          Get-Process                   7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Get-Service                   7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Get-Variable                  7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Get-Volume                    7.4.0      ZirconOS.Storage");
        con.writeLine("Cmdlet          Restart-Computer              7.4.0      ZirconOS.Management");
        con.writeLine("Cmdlet          New-Item                      7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Remove-Item                   7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Set-Location                  7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Set-Variable                  7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Stop-Computer                 7.4.0      ZirconOS.Management");
        con.writeLine("Cmdlet          Test-Path                     7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Write-Host                    7.4.0      ZirconOS.Core");
        con.writeLine("Cmdlet          Write-Output                  7.4.0      ZirconOS.Core");
        con.writeLine("");
    }

    fn cmdGetAlias(self: *PowerShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine("CommandType     Name                         Definition");
        con.writeLine("-----------     ----                         ----------");
        for (self.aliases[0..self.alias_count]) |*a| {
            _ = con.writeOutput("Alias           ");
            _ = con.writeOutput(a.name[0..a.name_len]);
            var pad: usize = 0;
            while (pad + a.name_len < 29) : (pad += 1) {
                _ = con.writeOutput(" ");
            }
            con.writeLine(a.definition[0..a.definition_len]);
        }
        con.writeLine("");
    }

    fn cmdGetVariable(self: *PowerShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        con.writeLine("");
        con.writeLine("Name                           Value");
        con.writeLine("----                           -----");
        for (self.variables[0..self.var_count]) |*v| {
            if (trimmed.len > 0 and !strEqlI(v.name[0..v.name_len], trimmed)) continue;
            _ = con.writeOutput(v.name[0..v.name_len]);
            var pad: usize = 0;
            while (pad + v.name_len < 31) : (pad += 1) {
                _ = con.writeOutput(" ");
            }
            con.writeLine(v.value[0..v.value_len]);
        }
        con.writeLine("");
    }

    fn cmdSetVariable(self: *PowerShell, args: []const u8) void {
        const trimmed = trim(args);
        var space_pos: usize = trimmed.len;
        for (trimmed, 0..) |c, i| {
            if (c == ' ') {
                space_pos = i;
                break;
            }
        }
        if (space_pos < trimmed.len) {
            const var_name = trimmed[0..space_pos];
            const var_value = trim(trimmed[space_pos + 1 ..]);
            self.setVariable(var_name, var_value, false, false);
        }
    }

    fn cmdGetHistory(self: *PowerShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine("  Id CommandLine");
        con.writeLine("  -- -----------");
        for (self.history[0..self.history_count], 0..) |*h, i| {
            const h_len = self.history_len[i];
            if (h_len == 0) continue;
            var num_buf: [8]u8 = undefined;
            _ = con.writeOutput("  ");
            _ = con.writeOutput(formatUint(&num_buf, i + 1));
            _ = con.writeOutput("  ");
            con.writeLine(h[0..h_len]);
        }
        con.writeLine("");
    }

    fn cmdGetHost(self: *PowerShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine("Name             : ZirconOS PowerShell Host");
        con.writeLine("Version          : 7.4.0");
        con.writeLine("InstanceId       : 00000000-0000-0000-0000-000000000001");
        con.writeLine("UI               : ZirconOS.Console.UI");
        con.writeLine("CurrentCulture   : en-US");
        con.writeLine("CurrentUICulture : en-US");
        con.writeLine("");
    }

    fn cmdGetContent(self: *PowerShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Get-Content: Cannot bind argument 'Path'. The argument is null or empty.");
            return;
        }
        con.writeLine("[File content display pending implementation]");
    }

    fn cmdNewItem(self: *PowerShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("New-Item: Missing required argument 'Path'.");
            return;
        }
        const vol = fat32.getVolume();
        if (vol.createFile(trimmed, 0x20)) |_| {
            _ = con.writeOutput("    Directory: C:\\\n\nMode         LastWriteTime  Length Name\n----         -------------  ------ ----\n-a----  2024/01/01  00:00       0 ");
            con.writeLine(trimmed);
        } else {
            con.writeLine("New-Item: Cannot create item, disk may be full.");
        }
    }

    fn cmdRemoveItem(self: *PowerShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Remove-Item: Missing required argument 'Path'.");
            return;
        }
        const vol = fat32.getVolume();
        if (!vol.removeEntry(trimmed)) {
            _ = con.writeOutput("Remove-Item: Cannot find path '");
            _ = con.writeOutput(trimmed);
            con.writeLine("'.");
        }
    }

    fn cmdTestPath(self: *PowerShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("False");
            return;
        }
        const vol = fat32.getVolume();
        if (vol.findEntry(trimmed)) |_| {
            con.writeLine("True");
        } else {
            con.writeLine("False");
        }
    }

    fn cmdStopComputer(self: *PowerShell, args: []const u8) void {
        const arch = @import("../../arch.zig");
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);

        var do_force = false;
        if (trimmed.len > 0) {
            if (strEqlI(trimmed, "-Force")) {
                do_force = true;
            } else if (strEqlI(trimmed, "-WhatIf")) {
                con.writeLine("What if: Performing the operation \"Stop-Computer\" on target \"localhost\".");
                return;
            } else if (strEqlI(trimmed, "-Confirm")) {
                con.writeLine("Confirm");
                con.writeLine("Are you sure you want to perform this action?");
                con.writeLine("Performing the operation \"Stop-Computer\" on target \"localhost\".");
                return;
            }
        }

        con.writeLine("");
        if (do_force) {
            con.writeLine("WARNING: Forcing shutdown - all applications will be terminated.");
        }
        klog.info("PowerShell: Stop-Computer executed (force=%s)", .{
            if (do_force) "yes" else "no",
        });
        con.writeLine("Shutting down the computer...");
        arch.shutdown();
    }

    fn cmdRestartComputer(self: *PowerShell, args: []const u8) void {
        const arch = @import("../../arch.zig");
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);

        var do_force = false;
        if (trimmed.len > 0) {
            if (strEqlI(trimmed, "-Force")) {
                do_force = true;
            } else if (strEqlI(trimmed, "-WhatIf")) {
                con.writeLine("What if: Performing the operation \"Restart-Computer\" on target \"localhost\".");
                return;
            } else if (strEqlI(trimmed, "-Confirm")) {
                con.writeLine("Confirm");
                con.writeLine("Are you sure you want to perform this action?");
                con.writeLine("Performing the operation \"Restart-Computer\" on target \"localhost\".");
                return;
            }
        }

        con.writeLine("");
        if (do_force) {
            con.writeLine("WARNING: Forcing restart - all applications will be terminated.");
        }
        klog.info("PowerShell: Restart-Computer executed (force=%s)", .{
            if (do_force) "yes" else "no",
        });
        con.writeLine("Restarting the computer...");
        arch.reset();
    }

    fn cmdShutdownExe(self: *PowerShell, args: []const u8) void {
        const arch = @import("../../arch.zig");
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);

        if (trimmed.len == 0) {
            con.writeLine("Usage: shutdown [/s | /r | /h | /l | /a] [/t xxx] [/f]");
            con.writeLine("  /s  Shutdown the computer.");
            con.writeLine("  /r  Restart the computer.");
            con.writeLine("  /h  Hibernate the local computer.");
            con.writeLine("  /l  Log off the current user.");
            con.writeLine("  /a  Abort a system shutdown.");
            con.writeLine("  /t  Set time-out period before shutdown (in seconds).");
            con.writeLine("  /f  Force running applications to close.");
            return;
        }

        var do_shutdown = false;
        var do_restart = false;
        var do_hibernate = false;
        var do_logoff = false;
        var do_abort = false;

        var i: usize = 0;
        while (i < trimmed.len) {
            if (trimmed[i] == '/' or trimmed[i] == '-') {
                i += 1;
                if (i >= trimmed.len) break;
                const flag = if (trimmed[i] >= 'A' and trimmed[i] <= 'Z') trimmed[i] + 32 else trimmed[i];
                switch (flag) {
                    's' => do_shutdown = true,
                    'r' => do_restart = true,
                    'h' => do_hibernate = true,
                    'l' => do_logoff = true,
                    'a' => do_abort = true,
                    'f', 't' => {},
                    else => {
                        con.writeLine("Invalid argument/option.");
                        return;
                    },
                }
                i += 1;
            } else {
                i += 1;
            }
        }

        if (do_abort) {
            con.writeLine("The scheduled shutdown has been cancelled.");
            return;
        }
        if (do_logoff) {
            con.writeLine("Logging off...");
            self.state = .exiting;
            return;
        }
        if (do_hibernate) {
            con.writeLine("The system is entering hibernation mode.");
            klog.info("PowerShell: shutdown /h - hibernate", .{});
            arch.halt();
        }
        if (do_restart) {
            con.writeLine("Restarting the system...");
            klog.info("PowerShell: shutdown /r - restart", .{});
            arch.reset();
        }
        if (do_shutdown) {
            con.writeLine("Shutting down the system...");
            klog.info("PowerShell: shutdown /s - shutdown", .{});
            arch.shutdown();
        }

        con.writeLine("No valid shutdown action specified.");
    }

    fn cmdDiskpart(self: *PowerShell) void {
        diskpart.runInteractive(self.console_id);
    }

    fn cmdGetDisk(self: *PowerShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        const dp = diskpart.getState();
        if (!diskpart.isInitialized()) diskpart.init();
        con.writeLine("");
        con.writeLine("Number Friendly Name      Serial Number  HealthStatus  OperationalStatus  Total Size  Partition Style");
        con.writeLine("------ -------------      -------------  ------------  -----------------  ----------  ---------------");
        var i: u32 = 0;
        while (i < dp.disk_count) : (i += 1) {
            const d = &dp.disks[i];
            if (!d.in_use) continue;
            var buf: [16]u8 = undefined;
            _ = con.writeOutput(formatUint(&buf, i));
            _ = con.writeOutput("      ");
            _ = con.writeOutput(d.model[0..d.model_len]);
            _ = con.writeOutput("  ");
            _ = con.writeOutput("ZR00000");
            _ = con.writeOutput(formatUint(&buf, i));
            _ = con.writeOutput("      Healthy       ");
            if (d.status == .online) {
                _ = con.writeOutput("Online             ");
            } else {
                _ = con.writeOutput("Offline            ");
            }
            _ = con.writeOutput(formatUint(&buf, d.size_mb));
            _ = con.writeOutput(" MB      ");
            if (d.style == .gpt) {
                _ = con.writeOutput("GPT");
            } else if (d.style == .mbr) {
                _ = con.writeOutput("MBR");
            } else {
                _ = con.writeOutput("RAW");
            }
            con.writeLine("");
        }
        con.writeLine("");
    }

    fn cmdGetPartition(self: *PowerShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        const dp = diskpart.getState();
        if (!diskpart.isInitialized()) diskpart.init();
        con.writeLine("");
        con.writeLine("   DiskNumber PartitionNumber  DriveLetter Offset         Size Type");
        con.writeLine("   ---------- ---------------  ----------- ------         ---- ----");
        var di: u32 = 0;
        while (di < dp.disk_count) : (di += 1) {
            const d = &dp.disks[di];
            if (!d.in_use) continue;
            var pi: u32 = 0;
            while (pi < d.partition_count) : (pi += 1) {
                const p = &d.partitions[pi];
                if (!p.in_use) continue;
                var buf: [16]u8 = undefined;
                _ = con.writeOutput("   ");
                _ = con.writeOutput(formatUint(&buf, di));
                _ = con.writeOutput("           ");
                _ = con.writeOutput(formatUint(&buf, p.number));
                _ = con.writeOutput("                ");
                if (p.drive_letter != 0) {
                    _ = con.writeOutput(&[_]u8{p.drive_letter});
                } else {
                    _ = con.writeOutput(" ");
                }
                _ = con.writeOutput("           ");
                _ = con.writeOutput(formatUint(&buf, p.offset_mb));
                _ = con.writeOutput(" MB         ");
                _ = con.writeOutput(formatUint(&buf, p.size_mb));
                _ = con.writeOutput(" MB  ");
                if (p.part_type == .primary) {
                    _ = con.writeOutput("Basic");
                } else if (p.part_type == .efi_system) {
                    _ = con.writeOutput("System");
                } else {
                    _ = con.writeOutput("Basic");
                }
                con.writeLine("");
            }
        }
        con.writeLine("");
    }

    fn cmdGetVolume(self: *PowerShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        const dp = diskpart.getState();
        if (!diskpart.isInitialized()) diskpart.init();
        con.writeLine("");
        con.writeLine("DriveLetter FriendlyName    FileSystemType  DriveType  HealthStatus  SizeRemaining  Size");
        con.writeLine("----------- ------------    --------------  ---------  ------------  -------------  ----");
        var i: u32 = 0;
        while (i < dp.volume_count) : (i += 1) {
            const v = &dp.volumes[i];
            if (!v.in_use) continue;
            var buf: [16]u8 = undefined;
            if (v.drive_letter != 0) {
                _ = con.writeOutput(&[_]u8{v.drive_letter});
            } else {
                _ = con.writeOutput(" ");
            }
            _ = con.writeOutput("           ");
            _ = con.writeOutput(v.label[0..v.label_len]);
            var pad: usize = 0;
            while (pad + v.label_len < 16) : (pad += 1) {
                _ = con.writeOutput(" ");
            }
            const fs_str = switch (v.fs_type) {
                .fat32 => "FAT32           ",
                .ntfs => "NTFS            ",
                .devfs => "DevFS           ",
                .unknown => "Unknown         ",
            };
            _ = con.writeOutput(fs_str);
            _ = con.writeOutput("Fixed      Healthy       ");
            _ = con.writeOutput(formatUint(&buf, v.free_mb));
            _ = con.writeOutput(" MB         ");
            _ = con.writeOutput(formatUint(&buf, v.size_mb));
            _ = con.writeOutput(" MB");
            con.writeLine("");
        }
        con.writeLine("");
    }

    fn addHistory(self: *PowerShell, cmd: []const u8) void {
        if (self.history_count >= MAX_HISTORY) return;
        const copy_len = @min(cmd.len, MAX_CMD_LEN);
        @memcpy(self.history[self.history_count][0..copy_len], cmd[0..copy_len]);
        self.history_len[self.history_count] = copy_len;
        self.history_count += 1;
    }
};

// ── Global PowerShell instance ──

var ps_shell: PowerShell = .{};
var ps_initialized: bool = false;

pub fn init() void {
    ps_shell.init();
    ps_initialized = true;
    klog.info("PowerShell: Shell initialized (version=%s)", .{PS_VERSION_FULL});
}

pub fn getShell() *PowerShell {
    return &ps_shell;
}

pub fn runBootSequence() void {
    if (!ps_initialized) init();

    ps_shell.showBanner();
    ps_shell.showPrompt();

    const demo_commands = [_][]const u8{
        "Get-Host",
        "Get-Process",
        "Get-ChildItem",
        "Get-Service",
    };

    for (demo_commands) |cmd_str| {
        ps_shell.executeCommand(cmd_str);
        ps_shell.showPrompt();
    }
}

pub fn runInteractiveShell() noreturn {
    const arch = @import("../../arch.zig");

    if (!ps_initialized) init();

    ps_shell.showBanner();
    ps_shell.showPrompt();

    var line_buf: [MAX_CMD_LEN]u8 = undefined;
    var line_len: usize = 0;

    while (true) {
        const ch_opt = arch.readInputChar();
        if (ch_opt) |ch| {
            switch (ch) {
                '\n', '\r' => {
                    const con = console.getConsole(ps_shell.console_id);
                    if (con) |c| {
                        c.writeLine("");
                    }
                    if (line_len > 0) {
                        ps_shell.executeCommand(line_buf[0..line_len]);
                    }
                    if (ps_shell.state == .exiting) {
                        klog.info("PowerShell: Shell exited", .{});
                        break;
                    }
                    ps_shell.showPrompt();
                    line_len = 0;
                },
                0x08, 0x7F => {
                    if (line_len > 0) {
                        line_len -= 1;
                        const con = console.getConsole(ps_shell.console_id);
                        if (con) |c| {
                            _ = c.writeOutput("\x08 \x08");
                        }
                    }
                },
                0x03 => {
                    const con = console.getConsole(ps_shell.console_id);
                    if (con) |c| {
                        c.writeLine("^C");
                    }
                    line_len = 0;
                    ps_shell.showPrompt();
                },
                else => {
                    if (ch >= 0x20 and ch < 0x7F and line_len < MAX_CMD_LEN - 1) {
                        line_buf[line_len] = ch;
                        line_len += 1;
                        const con = console.getConsole(ps_shell.console_id);
                        if (con) |c| {
                            _ = c.writeOutput(&[_]u8{ch});
                        }
                    }
                },
            }
        } else {
            arch.waitForInterrupt();
        }
    }
    arch.halt();
}

pub fn isInitialized() bool {
    return ps_initialized;
}

// ── Utility Functions ──

fn strEqlI(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const ax = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const by = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (ax != by) return false;
    }
    return true;
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) start += 1;
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r' or s[end - 1] == '\n')) end -= 1;
    return s[start..end];
}

fn formatUint(buf: []u8, value: usize) []const u8 {
    const digits = "0123456789";
    var tmp: [20]u8 = undefined;
    var len: usize = 0;
    var n = value;

    if (n == 0) {
        tmp[0] = '0';
        len = 1;
    } else {
        while (n > 0) {
            tmp[len] = digits[n % 10];
            len += 1;
            n /= 10;
        }
    }

    var pos: usize = 0;
    var i = len;
    while (i > 0) {
        i -= 1;
        if (pos < buf.len) {
            buf[pos] = tmp[i];
            pos += 1;
        }
    }
    return buf[0..pos];
}
