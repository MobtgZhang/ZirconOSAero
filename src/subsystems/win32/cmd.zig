// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//! CMD.EXE - Command Prompt Shell
//! NT-compatible command interpreter with built-in commands.
//! Supports: dir, cd, cls, echo, type, mkdir, del, ver, help, set, exit, etc.

const std = @import("std");
const console = @import("console.zig");
const diskpart = @import("diskpart.zig");
const kernel32 = @import("../../libs/kernel32.zig");
const vfs = @import("../../fs/vfs.zig");
const fat32 = @import("../../fs/fat32.zig");
const ntfs = @import("../../fs/ntfs.zig");
const process = @import("../../ps/process.zig");
const klog = @import("../../rtl/klog.zig");
const scheduler = @import("../../ke/scheduler.zig");
const hal = @import("../../hal.zig");

pub const CMD_VERSION = "ZirconOS CMD [Version 1.0.0]";
pub const COPYRIGHT = "(C) ZirconOS Project. All rights reserved.";

const MAX_CMD_LEN: usize = 256;
const MAX_HISTORY: usize = 32;
const MAX_ENV_VARS: usize = 64;
const MAX_ALIASES: usize = 32;

pub const ShellState = enum {
    idle,
    running,
    executing_command,
    exiting,
};

pub const EnvVar = struct {
    name: [64]u8 = std.mem.zeroes([64]u8),
    name_len: usize = 0,
    value: [128]u8 = std.mem.zeroes([128]u8),
    value_len: usize = 0,
};

pub const CmdAlias = struct {
    name: [32]u8 = std.mem.zeroes([32]u8),
    name_len: usize = 0,
    command: [128]u8 = std.mem.zeroes([128]u8),
    command_len: usize = 0,
};

pub const CmdShell = struct {
    state: ShellState = .idle,
    current_dir: [260]u8 = std.mem.zeroes([260]u8),
    current_dir_len: usize = 0,
    history: [MAX_HISTORY][MAX_CMD_LEN]u8 = std.mem.zeroes([MAX_HISTORY][MAX_CMD_LEN]u8),
    history_len: [MAX_HISTORY]usize = std.mem.zeroes([MAX_HISTORY]usize),
    history_count: usize = 0,
    env_vars: [MAX_ENV_VARS]EnvVar = std.mem.zeroes([MAX_ENV_VARS]EnvVar),
    env_count: usize = 0,
    aliases: [MAX_ALIASES]CmdAlias = std.mem.zeroes([MAX_ALIASES]CmdAlias),
    alias_count: usize = 0,
    echo_on: bool = true,
    exit_code: u32 = 0,
    console_id: u32 = 0,

    pub fn init(self: *CmdShell) void {
        self.state = .running;
        const dir = "C:\\";
        @memcpy(self.current_dir[0..dir.len], dir);
        self.current_dir_len = dir.len;

        self.setEnv("SystemRoot", "C:\\Windows");
        self.setEnv("SystemDrive", "C:");
        self.setEnv("COMPUTERNAME", "ZIRCONOS");
        self.setEnv("USERNAME", "System");
        self.setEnv("USERPROFILE", "C:\\Users\\System");
        self.setEnv("COMSPEC", "C:\\Windows\\System32\\cmd.exe");
        self.setEnv("PATH", "C:\\Windows\\System32;C:\\Windows");
        self.setEnv("PATHEXT", ".COM;.EXE;.BAT;.CMD");
        self.setEnv("PROMPT", "$P$G");
        self.setEnv("OS", "ZirconOS_NT");
        self.setEnv("PROCESSOR_ARCHITECTURE", hal.processorArchitectureName());
        self.setEnv("NUMBER_OF_PROCESSORS", "1");
    }

    pub fn setEnv(self: *CmdShell, name: []const u8, value: []const u8) void {
        for (self.env_vars[0..self.env_count]) |*ev| {
            if (strEqlI(ev.name[0..ev.name_len], name)) {
                const v_copy = @min(value.len, ev.value.len);
                @memcpy(ev.value[0..v_copy], value[0..v_copy]);
                ev.value_len = v_copy;
                return;
            }
        }
        if (self.env_count >= MAX_ENV_VARS) return;
        var ev = &self.env_vars[self.env_count];
        const n_copy = @min(name.len, ev.name.len);
        @memcpy(ev.name[0..n_copy], name[0..n_copy]);
        ev.name_len = n_copy;
        const v_copy = @min(value.len, ev.value.len);
        @memcpy(ev.value[0..v_copy], value[0..v_copy]);
        ev.value_len = v_copy;
        self.env_count += 1;
    }

    pub fn getEnv(self: *CmdShell, name: []const u8) ?[]const u8 {
        for (self.env_vars[0..self.env_count]) |*ev| {
            if (strEqlI(ev.name[0..ev.name_len], name)) {
                return ev.value[0..ev.value_len];
            }
        }
        return null;
    }

    pub fn showBanner(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine(CMD_VERSION);
        con.writeLine(COPYRIGHT);
        con.writeLine("");
    }

    pub fn showPrompt(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = con.writeOutput(self.current_dir[0..self.current_dir_len]);
        _ = con.writeOutput(">");
    }

    pub fn executeCommand(self: *CmdShell, input: []const u8) void {
        if (input.len == 0) return;

        self.addHistory(input);
        self.state = .executing_command;

        var cmd_buf: [MAX_CMD_LEN]u8 = undefined;
        const trimmed = trim(input);
        const cmd_len = @min(trimmed.len, cmd_buf.len);
        @memcpy(cmd_buf[0..cmd_len], trimmed[0..cmd_len]);

        var cmd_name_end: usize = 0;
        while (cmd_name_end < cmd_len and cmd_buf[cmd_name_end] != ' ') {
            cmd_name_end += 1;
        }

        const cmd_name = cmd_buf[0..cmd_name_end];
        const args_start = if (cmd_name_end < cmd_len) cmd_name_end + 1 else cmd_len;
        const args = cmd_buf[args_start..cmd_len];

        if (strEqlI(cmd_name, "dir")) {
            self.cmdDir(args);
        } else if (strEqlI(cmd_name, "cd") or strEqlI(cmd_name, "chdir")) {
            self.cmdCd(args);
        } else if (strEqlI(cmd_name, "cls")) {
            self.cmdCls();
        } else if (strEqlI(cmd_name, "echo")) {
            self.cmdEcho(args);
        } else if (strEqlI(cmd_name, "type")) {
            self.cmdType(args);
        } else if (strEqlI(cmd_name, "mkdir") or strEqlI(cmd_name, "md")) {
            self.cmdMkdir(args);
        } else if (strEqlI(cmd_name, "del") or strEqlI(cmd_name, "erase")) {
            self.cmdDel(args);
        } else if (strEqlI(cmd_name, "ver")) {
            self.cmdVer();
        } else if (strEqlI(cmd_name, "help")) {
            self.cmdHelp();
        } else if (strEqlI(cmd_name, "set")) {
            self.cmdSet(args);
        } else if (strEqlI(cmd_name, "exit")) {
            self.cmdExit();
        } else if (strEqlI(cmd_name, "date")) {
            self.cmdDate();
        } else if (strEqlI(cmd_name, "time")) {
            self.cmdTime();
        } else if (strEqlI(cmd_name, "systeminfo")) {
            self.cmdSystemInfo();
        } else if (strEqlI(cmd_name, "tasklist")) {
            self.cmdTaskList();
        } else if (strEqlI(cmd_name, "hostname")) {
            self.cmdHostname();
        } else if (strEqlI(cmd_name, "whoami")) {
            self.cmdWhoami();
        } else if (strEqlI(cmd_name, "vol")) {
            self.cmdVol();
        } else if (strEqlI(cmd_name, "title")) {
            self.cmdTitle(args);
        } else if (strEqlI(cmd_name, "color")) {
            self.cmdColor(args);
        } else if (strEqlI(cmd_name, "path")) {
            self.cmdPath(args);
        } else if (strEqlI(cmd_name, "shutdown") or strEqlI(cmd_name, "shutdown.exe")) {
            self.cmdShutdown(args);
        } else if (strEqlI(cmd_name, "diskpart")) {
            self.cmdDiskpart();
        } else if (strEqlI(cmd_name, "copy")) {
            self.cmdCopy(args);
        } else if (strEqlI(cmd_name, "move")) {
            self.cmdMove(args);
        } else if (strEqlI(cmd_name, "ren") or strEqlI(cmd_name, "rename")) {
            self.cmdRen(args);
        } else if (strEqlI(cmd_name, "rmdir") or strEqlI(cmd_name, "rd")) {
            self.cmdRmdir(args);
        } else if (strEqlI(cmd_name, "tree")) {
            self.cmdTree();
        } else if (strEqlI(cmd_name, "pause")) {
            self.cmdPause();
        } else if (strEqlI(cmd_name, "attrib")) {
            self.cmdAttrib(args);
        } else if (strEqlI(cmd_name, "more")) {
            self.cmdMore(args);
        } else if (strEqlI(cmd_name, "fc")) {
            self.cmdFc(args);
        } else if (strEqlI(cmd_name, "find")) {
            self.cmdFind(args);
        } else if (strEqlI(cmd_name, "sort")) {
            self.cmdSort(args);
        } else if (strEqlI(cmd_name, "label")) {
            self.cmdLabel(args);
        } else if (strEqlI(cmd_name, "subst")) {
            self.cmdSubst(args);
        } else if (strEqlI(cmd_name, "ipconfig")) {
            self.cmdIpconfig();
        } else if (strEqlI(cmd_name, "ping")) {
            self.cmdPing(args);
        } else if (strEqlI(cmd_name, "net")) {
            self.cmdNet(args);
        } else if (strEqlI(cmd_name, "taskkill")) {
            self.cmdTaskkill(args);
        } else if (strEqlI(cmd_name, "start")) {
            self.cmdStart(args);
        } else if (strEqlI(cmd_name, "chkdsk")) {
            self.cmdChkdsk();
        } else if (strEqlI(cmd_name, "notepad")) {
            self.cmdNotepad(args);
        } else if (strEqlI(cmd_name, "reg")) {
            self.cmdReg(args);
        } else if (strEqlI(cmd_name, "sc")) {
            self.cmdSc(args);
        } else if (strEqlI(cmd_name, "xcopy")) {
            self.cmdXcopy(args);
        } else if (strEqlI(cmd_name, "robocopy")) {
            self.cmdRobocopy(args);
        } else if (strEqlI(cmd_name, "pushd")) {
            self.cmdPushd(args);
        } else if (strEqlI(cmd_name, "popd")) {
            self.cmdPopd();
        } else if (strEqlI(cmd_name, "where")) {
            self.cmdWhere(args);
        } else if (strEqlI(cmd_name, "winver")) {
            self.cmdWinver();
        } else if (strEqlI(cmd_name, "verify")) {
            self.cmdVerify(args);
        } else if (strEqlI(cmd_name, "nslookup")) {
            self.cmdNslookup(args);
        } else if (strEqlI(cmd_name, "netstat")) {
            self.cmdNetstat();
        } else if (strEqlI(cmd_name, "tracert")) {
            self.cmdTracert(args);
        } else if (strEqlI(cmd_name, "runas")) {
            self.cmdRunas(args);
        } else if (strEqlI(cmd_name, "mklink")) {
            self.cmdMklink(args);
        } else if (strEqlI(cmd_name, "cacls")) {
            self.cmdCacls(args);
        } else if (strEqlI(cmd_name, "chkntfs")) {
            self.cmdChkntfs();
        } else if (strEqlI(cmd_name, "cipher")) {
            self.cmdCipher(args);
        } else if (strEqlI(cmd_name, "compact")) {
            self.cmdCompact(args);
        } else if (strEqlI(cmd_name, "defrag")) {
            self.cmdDefrag();
        } else if (strEqlI(cmd_name, "format")) {
            self.cmdFormat(args);
        } else if (strEqlI(cmd_name, "fsutil")) {
            self.cmdFsutil(args);
        } else if (strEqlI(cmd_name, "ftype")) {
            self.cmdFtype(args);
        } else if (strEqlI(cmd_name, "mode")) {
            self.cmdMode(args);
        } else if (strEqlI(cmd_name, "mountvol")) {
            self.cmdMountvol();
        } else if (strEqlI(cmd_name, "print")) {
            self.cmdPrint(args);
        } else if (strEqlI(cmd_name, "recover")) {
            self.cmdRecover(args);
        } else if (strEqlI(cmd_name, "replace")) {
            self.cmdReplace(args);
        } else if (strEqlI(cmd_name, "route")) {
            self.cmdRoute(args);
        } else if (strEqlI(cmd_name, "schtasks")) {
            self.cmdSchtasks(args);
        } else if (strEqlI(cmd_name, "sfc")) {
            self.cmdSfc();
        } else if (strEqlI(cmd_name, "setx")) {
            self.cmdSetx(args);
        } else if (strEqlI(cmd_name, "takeown")) {
            self.cmdTakeown(args);
        } else if (strEqlI(cmd_name, "telnet")) {
            self.cmdTelnet(args);
        } else if (strEqlI(cmd_name, "tftp")) {
            self.cmdTftp(args);
        } else if (strEqlI(cmd_name, "wmic")) {
            self.cmdWmic(args);
        } else if (strEqlI(cmd_name, "winmgmt")) {
            self.cmdWinmgmt();
        } else if (strEqlI(cmd_name, "assoc")) {
            self.cmdAssoc(args);
        } else if (strEqlI(cmd_name, "bcdedit")) {
            self.cmdBcdedit(args);
        } else if (strEqlI(cmd_name, "break")) {
            self.cmdBreak();
        } else if (strEqlI(cmd_name, "chcp")) {
            self.cmdChcp();
        } else if (strEqlI(cmd_name, "cmdkey")) {
            self.cmdCmdkey(args);
        } else if (strEqlI(cmd_name, "comp")) {
            self.cmdComp(args);
        } else if (strEqlI(cmd_name, "convert")) {
            self.cmdConvert(args);
        } else if (strEqlI(cmd_name, "cscript")) {
            self.cmdCscript(args);
        } else if (strEqlI(cmd_name, "doskey")) {
            self.cmdDoskey(args);
        } else if (strEqlI(cmd_name, "driverquery")) {
            self.cmdDriverquery();
        } else if (strEqlI(cmd_name, "eventcreate")) {
            self.cmdEventcreate(args);
        } else if (strEqlI(cmd_name, "expand")) {
            self.cmdExpand(args);
        } else if (strEqlI(cmd_name, "explorer")) {
            self.cmdExplorer(args);
        } else if (strEqlI(cmd_name, "msconfig")) {
            self.cmdMsconfig();
        } else if (strEqlI(cmd_name, "msinfo32")) {
            self.cmdMsinfo32();
        } else if (strEqlI(cmd_name, "findstr")) {
            self.cmdFindstr(args);
        } else if (strEqlI(cmd_name, "forfiles")) {
            self.cmdForfiles(args);
        } else if (strEqlI(cmd_name, "goto")) {
            self.cmdGoto(args);
        } else if (strEqlI(cmd_name, "gpresult")) {
            self.cmdGpresult();
        } else if (strEqlI(cmd_name, "gpupdate")) {
            self.cmdGpupdate();
        } else if (strEqlI(cmd_name, "getmac")) {
            self.cmdGetmac();
        } else if (strEqlI(cmd_name, "icacls")) {
            self.cmdIcacls(args);
        } else if (strEqlI(cmd_name, "logoff")) {
            self.cmdLogoff();
        } else if (strEqlI(cmd_name, "mstsc")) {
            self.cmdMstsc(args);
        } else if (strEqlI(cmd_name, "netsh")) {
            self.cmdNetsh(args);
        } else if (strEqlI(cmd_name, "openfiles")) {
            self.cmdOpenfiles(args);
        } else if (strEqlI(cmd_name, "pathping")) {
            self.cmdPathping(args);
        } else if (strEqlI(cmd_name, "prompt")) {
            self.cmdPrompt(args);
        } else if (strEqlI(cmd_name, "rem")) {
            // REM is a no-op comment command
        } else if (strEqlI(cmd_name, "setlocal")) {
            self.cmdSetlocal();
        } else if (strEqlI(cmd_name, "endlocal")) {
            self.cmdEndlocal();
        } else if (strEqlI(cmd_name, "shift")) {
            self.cmdShift();
        } else if (strEqlI(cmd_name, "timeout")) {
            self.cmdTimeout(args);
        } else if (strEqlI(cmd_name, "tskill")) {
            self.cmdTskill(args);
        } else if (strEqlI(cmd_name, "typeperf")) {
            self.cmdTypeperf(args);
        } else if (strEqlI(cmd_name, "vssadmin")) {
            self.cmdVssadmin(args);
        } else if (strEqlI(cmd_name, "w32tm")) {
            self.cmdW32tm(args);
        } else if (strEqlI(cmd_name, "nlsfunc")) {
            self.cmdNlsfunc(args);
        } else if (strEqlI(cmd_name, "waitfor")) {
            self.cmdWaitfor(args);
        } else if (strEqlI(cmd_name, "clip")) {
            self.cmdClip(args);
        } else if (strEqlI(cmd_name, "edit")) {
            self.cmdEdit(args);
        } else if (strEqlI(cmd_name, "eventquery")) {
            self.cmdEventquery(args);
        } else if (strEqlI(cmd_name, "for")) {
            self.cmdFor(args);
        } else if (strEqlI(cmd_name, "if")) {
            self.cmdIf(args);
        } else if (strEqlI(cmd_name, "inuse")) {
            self.cmdInuse(args);
        } else if (strEqlI(cmd_name, "klist")) {
            self.cmdKlist(args);
        } else if (strEqlI(cmd_name, "ksetup")) {
            self.cmdKsetup(args);
        } else if (strEqlI(cmd_name, "lodctr")) {
            self.cmdLodctr(args);
        } else if (strEqlI(cmd_name, "logman")) {
            self.cmdLogman(args);
        } else if (strEqlI(cmd_name, "lpq")) {
            self.cmdLpq(args);
        } else if (strEqlI(cmd_name, "lpr")) {
            self.cmdLpr(args);
        } else if (strEqlI(cmd_name, "msiexec")) {
            self.cmdMsiexec(args);
        } else if (strEqlI(cmd_name, "netcfg")) {
            self.cmdNetcfg(args);
        } else if (strEqlI(cmd_name, "ntsd")) {
            self.cmdNtsd(args);
        } else if (strEqlI(cmd_name, "ocsetup")) {
            self.cmdOcsetup(args);
        } else if (strEqlI(cmd_name, "perfmon")) {
            self.cmdPerfmon(args);
        } else if (strEqlI(cmd_name, "powercfg")) {
            self.cmdPowercfg(args);
        } else if (strEqlI(cmd_name, "psr")) {
            self.cmdPsr(args);
        } else if (strEqlI(cmd_name, "rasdial")) {
            self.cmdRasdial(args);
        } else if (strEqlI(cmd_name, "rcp")) {
            self.cmdRcp(args);
        } else if (strEqlI(cmd_name, "regini")) {
            self.cmdRegini(args);
        } else if (strEqlI(cmd_name, "regsvr32")) {
            self.cmdRegsvr32(args);
        } else if (strEqlI(cmd_name, "rexec")) {
            self.cmdRexec(args);
        } else if (strEqlI(cmd_name, "rpcping")) {
            self.cmdRpcping(args);
        } else if (strEqlI(cmd_name, "rsh")) {
            self.cmdRsh(args);
        } else if (strEqlI(cmd_name, "rwinsta")) {
            self.cmdRwinsta(args);
        } else if (strEqlI(cmd_name, "tcmsetup")) {
            self.cmdTcmsetup(args);
        } else if (strEqlI(cmd_name, "unlodctr")) {
            self.cmdUnlodctr(args);
        } else if (strEqlI(cmd_name, "verifier")) {
            self.cmdVerifier(args);
        } else if (strEqlI(cmd_name, "wscript")) {
            self.cmdWscript(args);
        } else if (strEqlI(cmd_name, "xwizard")) {
            self.cmdXwizard(args);
        } else if (strEqlI(cmd_name, "dsacls")) {
            self.cmdDsacls(args);
        } else if (strEqlI(cmd_name, "dsadd")) {
            self.cmdDsadd(args);
        } else if (strEqlI(cmd_name, "dsget")) {
            self.cmdDsget(args);
        } else if (strEqlI(cmd_name, "dsmod")) {
            self.cmdDsmod(args);
        } else if (strEqlI(cmd_name, "dsmove")) {
            self.cmdDsmove(args);
        } else if (strEqlI(cmd_name, "dsquery")) {
            self.cmdDsquery(args);
        } else if (strEqlI(cmd_name, "flattemp")) {
            self.cmdFlattemp(args);
        } else if (strEqlI(cmd_name, "chgport")) {
            self.cmdChgport(args);
        } else if (strEqlI(cmd_name, "chgusr")) {
            self.cmdChgusr(args);
        } else if (strEqlI(cmd_name, "cmstp")) {
            self.cmdCmstp(args);
        } else if (strEqlI(cmd_name, "eventtriggers")) {
            self.cmdEventtriggers(args);
        } else if (strEqlI(cmd_name, "ipxroute")) {
            self.cmdIpxroute(args);
        } else if (strEqlI(cmd_name, "mapadmin")) {
            self.cmdMapadmin(args);
        } else if (strEqlI(cmd_name, "nfsadmin")) {
            self.cmdNfsadmin(args);
        } else if (strEqlI(cmd_name, "prncnfg")) {
            self.cmdPrncnfg(args);
        } else if (strEqlI(cmd_name, "prndrvr")) {
            self.cmdPrndrvr(args);
        } else if (strEqlI(cmd_name, "prnjobs")) {
            self.cmdPrnjobs(args);
        } else if (strEqlI(cmd_name, "prnmngr")) {
            self.cmdPrnmngr(args);
        } else if (strEqlI(cmd_name, "prnport")) {
            self.cmdPrnport(args);
        } else if (strEqlI(cmd_name, "prnqctl")) {
            self.cmdPrnqctl(args);
        } else if (strEqlI(cmd_name, "pentnt")) {
            self.cmdPentnt(args);
        } else if (strEqlI(cmd_name, "bitsadmin")) {
            self.cmdBitsadmin(args);
        } else if (strEqlI(cmd_name, "bootcfg")) {
            self.cmdBootcfg(args);
        } else if (strEqlI(cmd_name, "certreq")) {
            self.cmdCertreq(args);
        } else if (strEqlI(cmd_name, "certutil")) {
            self.cmdCertutil(args);
        } else if (strEqlI(cmd_name, "choice")) {
            self.cmdChoice(args);
        } else if (strEqlI(cmd_name, "cmd")) {
            self.cmdNestedCmd();
        } else if (strEqlI(cmd_name, "dism")) {
            self.cmdDism(args);
        } else if (strEqlI(cmd_name, "dvdplay")) {
            self.cmdDvdplay(args);
        } else if (strEqlI(cmd_name, "eventvwr")) {
            self.cmdEventvwr(args);
        } else if (strEqlI(cmd_name, "fltmc")) {
            self.cmdFltmc(args);
        } else if (strEqlI(cmd_name, "iexpress")) {
            self.cmdIexpress(args);
        } else if (strEqlI(cmd_name, "makecab")) {
            self.cmdMakecab(args);
        } else if (strEqlI(cmd_name, "msg")) {
            self.cmdMsg(args);
        } else if (strEqlI(cmd_name, "nbtstat")) {
            self.cmdNbtstat(args);
        } else if (strEqlI(cmd_name, "qprocess")) {
            self.cmdQprocess(args);
        } else if (strEqlI(cmd_name, "query")) {
            self.cmdQuery(args);
        } else if (strEqlI(cmd_name, "quser")) {
            self.cmdQuser(args);
        } else if (strEqlI(cmd_name, "qwinsta")) {
            self.cmdQwinsta(args);
        } else if (strEqlI(cmd_name, "reset")) {
            self.cmdReset(args);
        } else if (strEqlI(cmd_name, "sxstrace")) {
            self.cmdSxstrace(args);
        } else if (strEqlI(cmd_name, "winrs")) {
            self.cmdWinrs(args);
        } else if (strEqlI(cmd_name, "arp")) {
            self.cmdArp(args);
        } else if (strEqlI(cmd_name, "at")) {
            self.cmdAt(args);
        } else if (strEqlI(cmd_name, "call")) {
            self.cmdCall(args);
        } else if (strEqlI(cmd_name, "dispdiag")) {
            self.cmdDispdiag(args);
        } else if (strEqlI(cmd_name, "nltest")) {
            self.cmdNltest(args);
        } else if (strEqlI(cmd_name, "qappsrv")) {
            self.cmdQappsrv(args);
        } else if (strEqlI(cmd_name, "tscon")) {
            self.cmdTscon(args);
        } else if (strEqlI(cmd_name, "tsdiscon")) {
            self.cmdTsdiscon(args);
        } else if (strEqlI(cmd_name, "delprof")) {
            self.cmdDelprof(args);
        } else if (strEqlI(cmd_name, "freedisk")) {
            self.cmdFreedisk(args);
        } else if (strEqlI(cmd_name, "auditpol")) {
            self.cmdAuditpol(args);
        } else if (strEqlI(cmd_name, "change")) {
            self.cmdChange(args);
        } else if (strEqlI(cmd_name, "ntbackup")) {
            self.cmdNtbackup(args);
        } else if (strEqlI(cmd_name, "secedit")) {
            self.cmdSecedit(args);
        } else if (strEqlI(cmd_name, "dxdiag")) {
            self.cmdDxdiag(args);
        } else if (strEqlI(cmd_name, "winsat")) {
            self.cmdWinsat(args);
        } else if (strEqlI(cmd_name, "msra")) {
            self.cmdMsra(args);
        } else if (strEqlI(cmd_name, "slmgr")) {
            self.cmdSlmgr(args);
        } else if (strEqlI(cmd_name, "sdbinst")) {
            self.cmdSdbinst(args);
        } else if (strEqlI(cmd_name, "sigverif")) {
            self.cmdSigverif(args);
        } else if (strEqlI(cmd_name, "wuauclt")) {
            self.cmdWuauclt(args);
        } else if (systemToolByName(cmd_name)) |tool| {
            self.cmdSystemTool(tool, args);
        } else if (cmd_name.len > 0) {
            const con = console.getConsole(self.console_id) orelse return;
            _ = con.writeOutput(cmd_name);
            con.writeLine("' is not recognized as an internal or external command,");
            con.writeLine("operable program or batch file.");
        }

        self.state = .running;
    }

    fn cmdDir(self: *CmdShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine(" Volume in drive C is ZIRCONOS");
        con.writeLine(" Volume Serial Number is 1234-5678");
        con.writeLine("");
        _ = con.writeOutput(" Directory of ");
        con.writeLine(self.current_dir[0..self.current_dir_len]);
        con.writeLine("");

        const is_root = (self.current_dir_len <= 3);
        if (!is_root) {
            con.writeLine("2024/01/01  00:00    <DIR>          .");
            con.writeLine("2024/01/01  00:00    <DIR>          ..");
        }

        var entries: [32]vfs.DirEntry = std.mem.zeroes([32]vfs.DirEntry);
        var total_files: usize = 0;
        var total_dirs: usize = 0;

        if (is_root) {
            const vol = fat32.getVolume();
            for (vol.root_entries[0..vol.root_entry_count]) |*fat_entry| {
                if (fat_entry.isFree() or fat_entry.isVolumeId()) continue;
                if (total_files + total_dirs >= entries.len) break;

                var e = &entries[total_files + total_dirs];
                e.* = .{};

                var pos: usize = 0;
                for (fat_entry.name) |c| {
                    if (c == ' ') break;
                    if (pos < e.name.len) {
                        e.name[pos] = c;
                        pos += 1;
                    }
                }
                var has_ext = false;
                for (fat_entry.ext) |c| {
                    if (c != ' ') {
                        has_ext = true;
                        break;
                    }
                }
                if (has_ext) {
                    if (pos < e.name.len) {
                        e.name[pos] = '.';
                        pos += 1;
                    }
                    for (fat_entry.ext) |c| {
                        if (c == ' ') break;
                        if (pos < e.name.len) {
                            e.name[pos] = c;
                            pos += 1;
                        }
                    }
                }
                e.name_len = pos;
                e.file_size = fat_entry.file_size;

                if (fat_entry.isDirectory()) {
                    e.file_type = .directory;
                    total_dirs += 1;
                } else {
                    e.file_type = .regular;
                    total_files += 1;
                }
            }
        } else {
            con.writeLine("               0 File(s)");
            con.writeLine("               2 Dir(s)");
            return;
        }

        const entry_count = total_files + total_dirs;
        var size_buf: [16]u8 = undefined;
        for (entries[0..entry_count]) |*e| {
            _ = con.writeOutput("2024/01/01  00:00    ");
            if (e.file_type == .directory) {
                _ = con.writeOutput("<DIR>          ");
            } else {
                const size_str = formatUint(&size_buf, @as(usize, @intCast(e.file_size)));
                var pad: usize = 0;
                while (pad + size_str.len < 15) : (pad += 1) {
                    _ = con.writeOutput(" ");
                }
                _ = con.writeOutput(size_str);
                _ = con.writeOutput(" ");
            }
            con.writeLine(e.name[0..e.name_len]);
        }

        con.writeLine("");
        var count_buf: [16]u8 = undefined;
        const file_str = formatUint(&count_buf, total_files);
        _ = con.writeOutput("               ");
        _ = con.writeOutput(file_str);
        con.writeLine(" File(s)");
        const dir_str = formatUint(&count_buf, total_dirs);
        _ = con.writeOutput("               ");
        _ = con.writeOutput(dir_str);
        con.writeLine(" Dir(s)");
    }

    fn cmdSystemTool(self: *CmdShell, tool: SystemTool, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = con.writeOutput(tool.display_name);
        _ = con.writeOutput(": ");
        if (trim(args).len == 0) {
            con.writeLine("type 'command /?' for the Windows 7 syntax reference.");
            return;
        }
        con.writeLine("operation is not available in this NT 6.1 compatibility profile.");
    }

    fn cmdCd(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine(self.current_dir[0..self.current_dir_len]);
            return;
        }
        if (trimmed.len == 2 and trimmed[0] == '.' and trimmed[1] == '.') {
            if (self.current_dir_len > 3) {
                var i = self.current_dir_len;
                if (i > 0 and self.current_dir[i - 1] == '\\') i -= 1;
                while (i > 3 and self.current_dir[i - 1] != '\\') i -= 1;
                if (i > 3) i -= 1;
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

    fn cmdCls(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.clear();
    }

    fn cmdEcho(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        if (args.len == 0) {
            if (self.echo_on) {
                con.writeLine("ECHO is on.");
            } else {
                con.writeLine("ECHO is off.");
            }
            return;
        }
        if (strEqlI(args, "on")) {
            self.echo_on = true;
            return;
        }
        if (strEqlI(args, "off")) {
            self.echo_on = false;
            return;
        }
        con.writeLine(args);
    }

    fn cmdType(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("The syntax of the command is incorrect.");
            return;
        }
        const vol = fat32.getVolume();
        const entry = vol.findEntry(trimmed);
        if (entry) |e| {
            if (e.isDirectory()) {
                con.writeLine("Access is denied.");
                return;
            }
            const cluster = e.getFirstCluster();
            if (cluster >= 2) {
                var read_buf: [4096]u8 = undefined;
                const bytes = vol.readData(cluster, &read_buf);
                if (bytes > 0) {
                    const display_len = @min(bytes, @as(usize, @intCast(e.file_size)));
                    if (display_len > 0) {
                        con.writeLine(read_buf[0..display_len]);
                    }
                } else {
                    con.writeLine("");
                }
            } else {
                con.writeLine("");
            }
        } else {
            _ = con.writeOutput("The system cannot find the file specified: ");
            con.writeLine(trimmed);
        }
    }

    fn cmdMkdir(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("The syntax of the command is incorrect.");
            return;
        }
        const vol = fat32.getVolume();
        if (vol.findEntry(trimmed) != null) {
            _ = con.writeOutput("A subdirectory or file ");
            _ = con.writeOutput(trimmed);
            con.writeLine(" already exists.");
            return;
        }
        if (vol.createDirectory(trimmed)) |_| {
            return;
        }
        con.writeLine("An error occurred while creating the directory.");
    }

    fn cmdDel(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("The syntax of the command is incorrect.");
            return;
        }
        const vol = fat32.getVolume();
        if (!vol.removeEntry(trimmed)) {
            _ = con.writeOutput("Could Not Find ");
            con.writeLine(trimmed);
        }
    }

    fn cmdVer(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine(CMD_VERSION);
        con.writeLine("");
    }

    fn cmdHelp(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("For more information on a specific command, type HELP command-name");
        con.writeLine("");
        con.writeLine("CD        Displays or changes the current directory.");
        con.writeLine("CHKDSK    Checks a disk and displays a status report.");
        con.writeLine("CLS       Clears the screen.");
        con.writeLine("COPY      Copies one or more files to another location.");
        con.writeLine("COLOR     Sets the console colors.");
        con.writeLine("DATE      Displays the date.");
        con.writeLine("DEL       Deletes one or more files.");
        con.writeLine("DIR       Displays a list of files and subdirectories.");
        con.writeLine("DISKPART  Opens the disk partitioning utility.");
        con.writeLine("ECHO      Displays messages, or turns command echoing on or off.");
        con.writeLine("FC        Compares two files or sets of files.");
        con.writeLine("FIND      Searches for a text string in a file or files.");
        con.writeLine("EXIT      Quits the CMD.EXE program.");
        con.writeLine("HELP      Provides help for commands.");
        con.writeLine("HOSTNAME  Prints the name of the host.");
        con.writeLine("MD        Creates a directory.");
        con.writeLine("MORE      Displays output one screen at a time.");
        con.writeLine("MOVE      Moves one or more files from one directory to another.");
        con.writeLine("NET       Manages network resources and services.");
        con.writeLine("NOTEPAD   Opens the Notepad text editor.");
        con.writeLine("PAUSE     Pauses execution and waits for a key press.");
        con.writeLine("PATH      Displays or sets a search path for executables.");
        con.writeLine("RD        Removes a directory.");
        con.writeLine("REN       Renames a file or directory.");
        con.writeLine("SC        Communicates with the Service Controller.");
        con.writeLine("SET       Displays, sets, or removes environment variables.");
        con.writeLine("SHUTDOWN  Shuts down, restarts, or logs off the system.");
        con.writeLine("SYSTEMINFO Displays system configuration information.");
        con.writeLine("TASKKILL  Terminates one or more running processes.");
        con.writeLine("TASKLIST  Displays all currently running processes.");
        con.writeLine("TIME      Displays the system time.");
        con.writeLine("TITLE     Sets the window title.");
        con.writeLine("TREE      Graphically displays the directory structure.");
        con.writeLine("TYPE      Displays the contents of a text file.");
        con.writeLine("VER       Displays the OS version.");
        con.writeLine("VOL       Displays a disk volume label.");
        con.writeLine("WHOAMI    Displays the current user name.");
        con.writeLine("XCOPY     Copies files and directory trees.");
        con.writeLine("ROBOCOPY  Robust file copy for Windows.");
        con.writeLine("PUSHD     Saves the current directory and changes to a new one.");
        con.writeLine("POPD      Restores the previous directory saved by PUSHD.");
        con.writeLine("WHERE     Displays the location of files matching a pattern.");
        con.writeLine("WINVER    Displays the Windows version dialog.");
        con.writeLine("VERIFY    Tells whether to verify files are written correctly.");
        con.writeLine("NSLOOKUP  Displays DNS lookups.");
        con.writeLine("NETSTAT   Displays network connections and statistics.");
        con.writeLine("TRACERT   Traces the route to a destination host.");
        con.writeLine("RUNAS     Runs a program as a different user.");
        con.writeLine("MKLINK    Creates symbolic links.");
        con.writeLine("CACLS     Displays or modifies file ACLs.");
        con.writeLine("CHKNTFS   Displays or modifies disk check scheduling.");
        con.writeLine("CIPHER    Encrypts or decrypts files on NTFS volumes.");
        con.writeLine("COMPACT   Displays or alters NTFS file compression.");
        con.writeLine("DEFRAG    Defragments a disk volume.");
        con.writeLine("FORMAT    Formats a disk for use with Windows.");
        con.writeLine("FSUTIL    Performs filesystem utility operations.");
        con.writeLine("FTYPE     Displays or modifies file extension associations.");
        con.writeLine("MODE      Configures system devices.");
        con.writeLine("MOUNTVOL  Displays or modifies mount points.");
        con.writeLine("PRINT     Prints a text file.");
        con.writeLine("RECOVER   Recovers readable information from a bad disk.");
        con.writeLine("REPLACE   Replaces files.");
        con.writeLine("ROUTE     Displays or modifies the IP routing table.");
        con.writeLine("SCHTASKS  Schedules commands and programs to run.");
        con.writeLine("SFC       Scans and replaces protected system files.");
        con.writeLine("SETX      Sets environment variables permanently.");
        con.writeLine("TAKEOWN   Takes ownership of a file or directory.");
        con.writeLine("TELNET    Connects to a remote host over Telnet.");
        con.writeLine("TFTP      Transfers files using TFTP protocol.");
        con.writeLine("WMIC      Displays WMI information.");
        con.writeLine("WINMGMT   Manages WMI infrastructure.");
        con.writeLine("ENDLOCAL  Ends localization of environment changes in a batch file.");
        con.writeLine("GETMAC    Displays the MAC addresses of network adapters.");
        con.writeLine("GPUPDATE  Refreshes Group Policy settings.");
        con.writeLine("MSCONFIG  Opens the System Configuration utility.");
        con.writeLine("MSINFO32  Displays detailed system information.");
    }

    fn cmdSet(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            for (self.env_vars[0..self.env_count]) |*ev| {
                _ = con.writeOutput(ev.name[0..ev.name_len]);
                _ = con.writeOutput("=");
                con.writeLine(ev.value[0..ev.value_len]);
            }
            return;
        }
        var eq_pos: usize = trimmed.len;
        for (trimmed, 0..) |c, i| {
            if (c == '=') {
                eq_pos = i;
                break;
            }
        }
        if (eq_pos < trimmed.len) {
            self.setEnv(trimmed[0..eq_pos], trimmed[eq_pos + 1 ..]);
        } else {
            if (self.getEnv(trimmed)) |val| {
                _ = con.writeOutput(trimmed);
                _ = con.writeOutput("=");
                con.writeLine(val);
            } else {
                con.writeLine("Environment variable not defined.");
            }
        }
    }

    fn cmdExit(self: *CmdShell) void {
        self.state = .exiting;
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Exiting CMD...");
    }

    fn cmdDate(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        var buf: [16]u8 = undefined;
        const ticks = scheduler.getTicks();
        const total_secs = ticks / 100;
        const days_since_boot = total_secs / 86400;
        const base_year: usize = 2024;
        const base_month: usize = 1;
        const base_day = 1 + days_since_boot;
        const day_of_week_names = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
        const dow_idx = days_since_boot % 7;
        _ = con.writeOutput("The current date is: ");
        _ = con.writeOutput(formatUint(&buf, base_year));
        _ = con.writeOutput("/");
        _ = con.writeOutput(formatUintPad2(&buf, base_month));
        _ = con.writeOutput("/");
        _ = con.writeOutput(formatUintPad2(&buf, @intCast(base_day)));
        _ = con.writeOutput(" ");
        con.writeLine(day_of_week_names[dow_idx]);
    }

    fn cmdTime(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        var count_buf: [16]u8 = undefined;
        const ticks = scheduler.getTicks();
        const secs = ticks / 100;
        const hrs = secs / 3600;
        const mins = (secs % 3600) / 60;
        const s = secs % 60;
        _ = con.writeOutput("The current time is: ");
        _ = con.writeOutput(formatUintPad2(&count_buf, @intCast(hrs)));
        _ = con.writeOutput(":");
        _ = con.writeOutput(formatUintPad2(&count_buf, @intCast(mins)));
        _ = con.writeOutput(":");
        con.writeLine(formatUintPad2(&count_buf, @intCast(s)));
    }

    fn cmdSystemInfo(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine("Host Name:                 ZIRCONOS");
        con.writeLine("OS Name:                   ZirconOS");
        con.writeLine("OS Version:                10.0.19041 Build 19041");
        con.writeLine("OS Manufacturer:           ZirconOS Project");
        con.writeLine("System Type:               ");
        _ = con.writeOutput(hal.processorArchitectureName());
        con.writeLine("-based PC");
        con.writeLine("Processor(s):              1 Processor(s) Installed.");
        _ = con.writeOutput("  [01]: ");
        _ = con.writeOutput(hal.processorArchitectureName());
        con.writeLine(" Family 6");

        var count_buf: [16]u8 = undefined;
        _ = con.writeOutput("Total Processes:           ");
        con.writeLine(formatUint(&count_buf, process.getProcessCount()));

        // 仅系统信息展示用堆「已提交−live」近似值；新内核分配应走 mm/ex_pool.zig（Ex* 语义）。
        const heap = @import("../../mm/heap.zig");
        _ = con.writeOutput("Available Physical Memory: ");
        _ = con.writeOutput(formatUint(&count_buf, heap.freeBytes() / 1024));
        con.writeLine(" KB");
        con.writeLine("Boot Device:               \\Device\\HarddiskVolume1");
        con.writeLine("System Directory:          C:\\Windows\\System32");
        con.writeLine("");
    }

    fn cmdTaskList(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        var count_buf: [16]u8 = undefined;
        con.writeLine("");
        con.writeLine("Image Name                     PID Session Name        Mem Usage");
        con.writeLine("========================= ======== ================ ===========");

        const proc_list = process.getProcessList();
        var shown: usize = 0;
        for (proc_list) |*p| {
            if (p.state != .active) continue;
            _ = con.writeOutput(p.name[0..p.name_len]);
            var pad: usize = p.name_len;
            while (pad < 26) : (pad += 1) {
                _ = con.writeOutput(" ");
            }
            const pid_str = formatUint(&count_buf, @as(usize, p.pid));
            var pid_pad: usize = pid_str.len;
            while (pid_pad < 8) : (pid_pad += 1) {
                _ = con.writeOutput(" ");
            }
            _ = con.writeOutput(pid_str);
            if (p.is_system) {
                _ = con.writeOutput(" Services");
            } else {
                _ = con.writeOutput(" Console ");
            }
            con.writeLine("                 0 K");
            shown += 1;
        }

        if (shown == 0) {
            con.writeLine("System                           1 Services                 0 K");
            con.writeLine("cmd.exe                          4 Console                  0 K");
        }
        con.writeLine("");
    }

    fn cmdHostname(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("ZIRCONOS");
    }

    fn cmdWhoami(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("zirconos\\system");
    }

    fn cmdVol(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine(" Volume in drive C is ZIRCONOS");
        con.writeLine(" Volume Serial Number is 1234-5678");
    }

    fn cmdTitle(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len > 0) {
            con.setTitle(trimmed);
        }
    }

    fn cmdColor(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Sets the default console foreground and background colors.");
            con.writeLine("");
            con.writeLine("COLOR [attr]");
            con.writeLine("");
            con.writeLine("  attr  Specifies color attribute of console output");
            con.writeLine("        The first hex digit is background, the second is foreground.");
            con.writeLine("        0=Black 1=Blue 2=Green 3=Cyan 4=Red 5=Magenta 6=Brown 7=White");
            return;
        }
        if (trimmed.len >= 2) {
            const bg_val = hexDigit(trimmed[0]);
            const fg_val = hexDigit(trimmed[1]);
            if (bg_val) |bg| {
                if (fg_val) |fg| {
                    con.setColor(@fromBackingInt(@intCast(fg)), @fromBackingInt(@intCast(bg)));
                    return;
                }
            }
        }
        con.writeLine("Invalid color specification.");
    }

    fn hexDigit(c: u8) ?u8 {
        if (c >= '0' and c <= '9') return c - '0';
        if (c >= 'a' and c <= 'f') return c - 'a' + 10;
        if (c >= 'A' and c <= 'F') return c - 'A' + 10;
        return null;
    }

    fn cmdPath(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            if (self.getEnv("PATH")) |val| {
                _ = con.writeOutput("PATH=");
                con.writeLine(val);
            }
        } else {
            self.setEnv("PATH", trimmed);
        }
    }

    fn cmdShutdown(self: *CmdShell, args: []const u8) void {
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
        var do_force = false;
        var timeout: u32 = 0;

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
                    'f' => do_force = true,
                    't' => {
                        i += 1;
                        while (i < trimmed.len and trimmed[i] == ' ') i += 1;
                        while (i < trimmed.len and trimmed[i] >= '0' and trimmed[i] <= '9') {
                            timeout = timeout * 10 + @as(u32, trimmed[i] - '0');
                            i += 1;
                        }
                        continue;
                    },
                    else => {
                        con.writeLine("Invalid argument/option - Check the usage with: shutdown /?");
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
            klog.info("CMD: User initiated logoff", .{});
            self.state = .exiting;
            return;
        }

        if (do_hibernate) {
            con.writeLine("Hibernating the system...");
            klog.info("CMD: User initiated hibernate", .{});
            con.writeLine("The system is entering hibernation mode.");
            arch.halt();
        }

        if (do_restart) {
            con.writeLine("");
            var buf: [16]u8 = undefined;
            if (timeout > 0) {
                _ = con.writeOutput("The system will restart in ");
                _ = con.writeOutput(formatUint(&buf, timeout));
                con.writeLine(" seconds.");
            }
            con.writeLine("Restarting the system...");
            klog.info("CMD: User initiated restart (timeout=%d, force=%s)", .{
                timeout, if (do_force) "yes" else "no",
            });
            arch.reset();
        }

        if (do_shutdown) {
            con.writeLine("");
            var buf: [16]u8 = undefined;
            if (timeout > 0) {
                _ = con.writeOutput("The system will shut down in ");
                _ = con.writeOutput(formatUint(&buf, timeout));
                con.writeLine(" seconds.");
            }
            con.writeLine("Shutting down the system...");
            klog.info("CMD: User initiated shutdown (timeout=%d, force=%s)", .{
                timeout, if (do_force) "yes" else "no",
            });
            arch.shutdown();
        }

        con.writeLine("No valid shutdown action specified. Use: shutdown /s or shutdown /r");
    }

    fn cmdDiskpart(self: *CmdShell) void {
        diskpart.runInteractive(self.console_id);
    }

    // ── File operations ──

    fn cmdCopy(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("The syntax of the command is incorrect.");
            return;
        }
        // Split "source destination" or "source,dest"
        var src: []const u8 = trimmed;
        var dst: []const u8 = "";
        if (std.mem.indexOfScalar(u8, trimmed, ' ')) |sep| {
            src = trim(trimmed[0..sep]);
            dst = trim(trimmed[sep + 1 ..]);
        }
        if (src.len == 0 or dst.len == 0) {
            con.writeLine("The syntax of the command is incorrect.");
            return;
        }
        const vol = fat32.getVolume();
        const entry = vol.findEntry(src) orelse {
            _ = con.writeOutput("The system cannot find the file specified: ");
            con.writeLine(src);
            return;
        };
        if (entry.isDirectory()) {
            con.writeLine("Access is denied.");
            return;
        }
        if (vol.findEntry(dst) != null) {
            _ = con.writeOutput("A file with the name ");
            _ = con.writeOutput(dst);
            con.writeLine(" already exists.");
            return;
        }
        const new_entry = vol.createFile(dst, 0) orelse {
            con.writeLine("The file cannot be copied because there is no free disk space.");
            return;
        };
        const src_cluster = entry.getFirstCluster();
        const dst_cluster = new_entry.getFirstCluster();
        if (src_cluster >= 2 and dst_cluster >= 2) {
            var buf: [512]u8 = undefined;
            var offset: usize = 0;
            const file_size: usize = @intCast(entry.file_size);
            while (offset < file_size) {
                const chunk = @min(buf.len, file_size - offset);
                const src_read = vol.readDataFromClusterChain(src_cluster, offset, buf[0..chunk]);
                if (src_read == 0) break;
                _ = vol.writeData(dst_cluster, buf[0..src_read]);
                offset += src_read;
            }
            new_entry.file_size = @intCast(offset);
            _ = con.writeOutput("        1 file(s) copied: ");
            _ = con.writeOutput(src);
            _ = con.writeOutput(" -> ");
            con.writeLine(dst);
        } else {
            con.writeLine("An error occurred while copying the file.");
        }
    }

    fn cmdMove(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("The syntax of the command is incorrect.");
            return;
        }
        var src: []const u8 = trimmed;
        var dst: []const u8 = "";
        if (std.mem.indexOfScalar(u8, trimmed, ' ')) |sep| {
            src = trim(trimmed[0..sep]);
            dst = trim(trimmed[sep + 1 ..]);
        }
        if (src.len == 0 or dst.len == 0) {
            con.writeLine("The syntax of the command is incorrect.");
            return;
        }
        const vol = fat32.getVolume();
        const entry = vol.findEntry(src) orelse {
            _ = con.writeOutput("The system cannot find the file specified: ");
            con.writeLine(src);
            return;
        };
        if (vol.findEntry(dst) != null) {
            _ = con.writeOutput("A file with the name ");
            _ = con.writeOutput(dst);
            con.writeLine(" already exists.");
            return;
        }
        const new_entry = vol.createFile(dst, 0) orelse {
            con.writeLine("The file cannot be moved.");
            return;
        };
        new_entry.file_size = entry.file_size;
        new_entry.setFirstCluster(entry.getFirstCluster());
        _ = vol.removeEntry(src);
        _ = con.writeOutput("        1 file(s) moved: ");
        _ = con.writeOutput(src);
        _ = con.writeOutput(" -> ");
        con.writeLine(dst);
    }

    fn cmdRen(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("The syntax of the command is incorrect.");
            return;
        }
        var src: []const u8 = trimmed;
        var dst: []const u8 = "";
        if (std.mem.indexOfScalar(u8, trimmed, ' ')) |sep| {
            src = trim(trimmed[0..sep]);
            dst = trim(trimmed[sep + 1 ..]);
        }
        if (src.len == 0 or dst.len == 0) {
            con.writeLine("The syntax of the command is incorrect.");
            return;
        }
        const vol = fat32.getVolume();
        const entry = vol.findEntry(src) orelse {
            _ = con.writeOutput("The system cannot find the file specified: ");
            con.writeLine(src);
            return;
        };
        if (vol.findEntry(dst) != null) {
            _ = con.writeOutput("A file with the name ");
            _ = con.writeOutput(dst);
            con.writeLine(" already exists.");
            return;
        }
        const new_entry = vol.createFile(dst, 0) orelse {
            con.writeLine("The file cannot be renamed.");
            return;
        };
        new_entry.file_size = entry.file_size;
        new_entry.setFirstCluster(entry.getFirstCluster());
        _ = vol.removeEntry(src);
    }

    fn cmdRmdir(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("The syntax of the command is incorrect.");
            return;
        }
        const vol = fat32.getVolume();
        const entry = vol.findEntry(trimmed);
        if (entry == null or !entry.?.isDirectory()) {
            _ = con.writeOutput("The system cannot find the path specified: ");
            con.writeLine(trimmed);
            return;
        }
        if (!vol.removeEntry(trimmed)) {
            con.writeLine("The directory is not empty.");
        }
    }

    fn cmdTree(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = con.writeOutput("C:.");
        con.writeLine("");
        _ = con.writeOutput("\\---");
        _ = con.writeOutput(self.current_dir[0..self.current_dir_len]);
        con.writeLine("");
        con.writeLine("    (No subdirectories found)");
    }

    fn cmdPause(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Press any key to continue . . .");
    }

    fn cmdAttrib(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("         A          \\");
            return;
        }
        const vol = fat32.getVolume();
        const entry = vol.findEntry(trimmed) orelse {
            _ = con.writeOutput("The system cannot find the file specified: ");
            con.writeLine(trimmed);
            return;
        };
        _ = con.writeOutput("         A");
        if (entry.isDirectory()) _ = con.writeOutput("   H");
        con.writeLine("");
    }

    fn cmdMore(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("The syntax of the command is incorrect.");
            return;
        }
        const vol = fat32.getVolume();
        const entry = vol.findEntry(trimmed) orelse {
            _ = con.writeOutput("The system cannot find the file specified: ");
            con.writeLine(trimmed);
            return;
        };
        if (entry.isDirectory()) {
            con.writeLine("Access is denied.");
            return;
        }
        const cluster = entry.getFirstCluster();
        if (cluster >= 2) {
            var read_buf: [512]u8 = undefined;
            const bytes = vol.readData(cluster, &read_buf);
            if (bytes > 0) {
                const display_len = @min(bytes, @as(usize, @intCast(entry.file_size)));
                con.writeLine(read_buf[0..display_len]);
            }
        }
    }

    fn cmdFc(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("The syntax of the command is incorrect.");
            return;
        }
        var f1: []const u8 = trimmed;
        var f2: []const u8 = "";
        if (std.mem.indexOfScalar(u8, trimmed, ' ')) |sep| {
            f1 = trim(trimmed[0..sep]);
            f2 = trim(trimmed[sep + 1 ..]);
        }
        if (f1.len == 0 or f2.len == 0) {
            con.writeLine("The syntax of the command is incorrect.");
            return;
        }
        const vol = fat32.getVolume();
        const e1 = vol.findEntry(f1);
        const e2 = vol.findEntry(f2);
        if (e1 == null or e2 == null) {
            con.writeLine("The system cannot find the file specified.");
            return;
        }
        if (e1.?.file_size != e2.?.file_size) {
            con.writeLine("Files are different.");
            return;
        }
        var buf1: [256]u8 = undefined;
        var buf2: [256]u8 = undefined;
        const c1 = e1.?.getFirstCluster();
        const c2 = e2.?.getFirstCluster();
        if (c1 >= 2 and c2 >= 2) {
            const s1 = vol.readData(c1, &buf1);
            const s2 = vol.readData(c2, &buf2);
            const cmp_len = @min(s1, s2);
            var identical = true;
            for (buf1[0..cmp_len], buf2[0..cmp_len]) |a, b| {
                if (a != b) {
                    identical = false;
                    break;
                }
            }
            if (identical) {
                con.writeLine("Files are identical.");
            } else {
                con.writeLine("Files are different.");
            }
        }
    }

    fn cmdFind(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len < 3 or trimmed[0] != '"') {
            con.writeLine("The syntax of the command is incorrect.");
            return;
        }
        const close_quote = std.mem.lastIndexOfScalar(u8, trimmed, '"') orelse {
            con.writeLine("The syntax of the command is incorrect.");
            return;
        };
        const search = trimmed[1..close_quote];
        const rest = trim(trimmed[close_quote + 1 ..]);
        if (rest.len == 0) {
            con.writeLine("The system cannot find the file specified.");
            return;
        }
        const vol = fat32.getVolume();
        const entry = vol.findEntry(rest) orelse {
            _ = con.writeOutput("The system cannot find the file specified: ");
            con.writeLine(rest);
            return;
        };
        const cluster = entry.getFirstCluster();
        if (cluster >= 2) {
            var buf: [512]u8 = undefined;
            const bytes = vol.readData(cluster, &buf);
            const data = buf[0..bytes];
            var found: usize = 0;
            var line_start: usize = 0;
            var line_no: usize = 1;
            for (data, 0..) |c, i| {
                if (c == '\n') {
                    const line = data[line_start..i];
                    if (std.mem.indexOf(u8, line, search) != null) found += 1;
                    line_start = i + 1;
                    line_no += 1;
                }
            }
            _ = con.writeOutput("Found ");
            var count_buf: [16]u8 = undefined;
            const count_str = formatUint(&count_buf, found);
            _ = con.writeOutput(count_str);
            _ = con.writeOutput(" occurrence(s) of \"");
            _ = con.writeOutput(search);
            _ = con.writeOutput("\" in ");
            con.writeLine(rest);
        }
    }

    fn cmdSort(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("The syntax of the command is incorrect.");
            return;
        }
        const vol = fat32.getVolume();
        const entry = vol.findEntry(trimmed) orelse {
            _ = con.writeOutput("The system cannot find the file specified: ");
            con.writeLine(trimmed);
            return;
        };
        const cluster = entry.getFirstCluster();
        if (cluster >= 2) {
            var buf: [512]u8 = undefined;
            const bytes = vol.readData(cluster, &buf);
            var pos: usize = 0;
            while (pos < bytes) {
                if (std.mem.indexOfScalar(u8, buf[pos..bytes], '\n')) |nl| {
                    con.writeLine(buf[pos .. pos + nl]);
                    pos += nl + 1;
                } else {
                    con.writeLine(buf[pos..bytes]);
                    break;
                }
            }
        }
    }

    fn cmdLabel(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("The label of drive C is: ZIRCONOS");
            return;
        }
        con.writeLine("The label of drive C has been changed.");
    }

    fn cmdSubst(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("No substitutions defined.");
            return;
        }
        _ = con.writeOutput("Substitution created for ");
        con.writeLine(trimmed);
    }

    // ── System / Network / Process ──

    fn cmdIpconfig(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine("Windows IP Configuration");
        con.writeLine("");
        con.writeLine("Ethernet adapter Ethernet:");
        con.writeLine("");
        con.writeLine("   Connection-specific DNS Suffix  . :");
        con.writeLine("   IPv4 Address. . . . . . . . . . . : 192.168.1.100");
        con.writeLine("   Subnet Mask . . . . . . . . . . . : 255.255.255.0");
        con.writeLine("   Default Gateway . . . . . . . . . : 192.168.1.1");
        con.writeLine("");
    }

    fn cmdPing(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: ping [-t] [-n count] <destination>");
            return;
        }
        _ = con.writeOutput("Pinging ");
        _ = con.writeOutput(trimmed);
        con.writeLine(" with 32 bytes of data:");
        con.writeLine("Request timed out.");
        con.writeLine("Request timed out.");
        con.writeLine("Request timed out.");
        con.writeLine("Request timed out.");
        con.writeLine("");
        con.writeLine("Ping statistics for 192.168.1.1:");
        con.writeLine("    Packets: Sent = 4, Received = 0, Lost = 4 (100% loss),");
    }

    fn cmdNet(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("The syntax of this command is:");
            con.writeLine("NET [ ACCOUNTS | COMPUTER | CONFIG | CONTINUE | FILE | GROUP | HELP | HELPMSG | LOCALGROUP | PAUSE | PRINT | SESSION | SHARE | START | STATISTICS | STOP | TIME | USE | USER | VIEW ]");
            return;
        }
        if (strEqlI(trimmed, "user")) {
            con.writeLine("User accounts for \\\\ZIRCONOS");
            con.writeLine("-----------------------------------------------------");
            con.writeLine("Administrator            Guest");
            return;
        }
        if (strEqlI(trimmed, "start")) {
            con.writeLine("Started the following services:");
            con.writeLine("   Workstation");
            con.writeLine("   Server");
            return;
        }
        if (strEqlI(trimmed, "view")) {
            con.writeLine("Server Name          Remark");
            con.writeLine("-----------------------------------------------------");
            con.writeLine("\\\\ZIRCONOS           ZirconOS Workstation");
            return;
        }
        _ = con.writeOutput("The service name is invalid: ");
        con.writeLine(trimmed);
    }

    fn cmdTaskkill(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: taskkill /PID <pid> | /IM <image_name>");
            return;
        }
        if (std.mem.startsWith(u8, trimmed, "/PID ")) {
            const pid_str = trim(trimmed[5..]);
            _ = con.writeOutput("SUCCESS: Sent termination signal to process with PID ");
            con.writeLine(pid_str);
            return;
        }
        if (std.mem.startsWith(u8, trimmed, "/IM ")) {
            const name = trim(trimmed[4..]);
            _ = con.writeOutput("SUCCESS: Sent termination signal to process \"");
            _ = con.writeOutput(name);
            con.writeLine("\"");
            return;
        }
        con.writeLine("The syntax of the command is incorrect.");
    }

    fn cmdStart(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Starts a program, command, or batch script.");
            return;
        }
        _ = con.writeOutput("Starting ");
        con.writeLine(trimmed);
    }

    fn cmdChkdsk(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("The type of the file system is FAT32.");
        con.writeLine("The volume is OK.");
        con.writeLine("No further action is required.");
        con.writeLine("");
        con.writeLine("      15,360 KB total disk space");
        con.writeLine("          2,048 KB in 12 files");
        con.writeLine("          1,024 KB in 4 indexes");
        con.writeLine("         13,312 KB available on disk");
    }

    fn cmdNotepad(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len > 0) {
            _ = con.writeOutput("Opening ");
            _ = con.writeOutput(trimmed);
            con.writeLine(" in Notepad...");
        } else {
            con.writeLine("Starting Notepad...");
        }
    }

    fn cmdReg(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: REG [QUERY | ADD | DELETE | COPY | SAVE | RESTORE | LOAD | UNLOAD | COMPARE | EXPORT | IMPORT | FLAGS] [/s] [/f]");
            return;
        }
        if (std.mem.startsWith(u8, trimmed, "query ")) {
            con.writeLine("HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion");
            con.writeLine("    SystemRoot    REG_SZ    C:\\Windows");
            return;
        }
        con.writeLine("The syntax of the command is incorrect.");
    }

    fn cmdSc(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: SC [QUERY | START | STOP | CONFIG | DELETE] <service>");
            return;
        }
        if (strEqlI(trimmed, "query")) {
            con.writeLine("SERVICE_NAME: schedule");
            con.writeLine("        TYPE       : 20 WIN32_SHARE_PROCESS");
            con.writeLine("        STATE      : 4 RUNNING");
            return;
        }
        con.writeLine("The service name is invalid.");
    }

    // ── Extended file / system commands ──

    fn cmdXcopy(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: XCOPY source [/A | /M] [/D[:date]] [/P] [/S [/E]] [/V] [/W] [/C] [/I] [/Q] [/F] [/L] [/G] [/H] [/R] [/T] [/U] [/K] [/N]");
            return;
        }
        var src: []const u8 = trimmed;
        var dst: []const u8 = "";
        if (std.mem.indexOfScalar(u8, trimmed, ' ')) |sep| {
            src = trim(trimmed[0..sep]);
            dst = trim(trimmed[sep + 1 ..]);
        }
        _ = con.writeOutput("Copying ");
        _ = con.writeOutput(src);
        _ = con.writeOutput(" -> ");
        con.writeLine(dst);
    }

    fn cmdRobocopy(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: ROBOCOPY <source> <destination> [file [...]] [options]");
            return;
        }
        con.writeLine("Robocopy operation completed.");
    }

    fn cmdPushd(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: PUSHD <path>");
            return;
        }
        _ = con.writeOutput("Changed directory to: ");
        con.writeLine(trimmed);
    }

    fn cmdPopd(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Returned to previous directory.");
    }

    fn cmdWhere(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: WHERE [/R dir /F /Q] pattern");
            return;
        }
        _ = con.writeOutput("Searching for ");
        _ = con.writeOutput(trimmed);
        con.writeLine(" in C:\\Windows\\System32...");
        con.writeLine("  C:\\Windows\\System32\\cmd.exe");
    }

    fn cmdWinver(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine("ZirconOS [Version 6.1.7601]");
        con.writeLine("Copyright (c) ZirconOS Project.  All rights reserved.");
        con.writeLine("");
    }

    fn cmdVerify(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("OFF");
            return;
        }
        _ = con.writeOutput("VERIFY is now ");
        con.writeLine(trimmed);
    }

    fn cmdNslookup(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Default Server:  dns.local");
            con.writeLine("Address:  192.168.1.1");
            return;
        }
        _ = con.writeOutput("Server:  dns.local");
        con.writeLine("");
        _ = con.writeOutput("Address:  192.168.1.1");
        con.writeLine("");
        _ = con.writeOutput("Name:    ");
        con.writeLine(trimmed);
        con.writeLine("Address:  192.168.1.100");
    }

    fn cmdNetstat(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Active Connections");
        con.writeLine("");
        con.writeLine("  Proto  Local Address          Foreign Address        State");
        con.writeLine("  TCP    127.0.0.1:135          0.0.0.0:0              LISTENING");
        con.writeLine("  TCP    127.0.0.1:445          0.0.0.0:0              LISTENING");
    }

    fn cmdTracert(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: TRACERT <destination>");
            return;
        }
        _ = con.writeOutput("Tracing route to ");
        con.writeLine(trimmed);
        con.writeLine("  1    <1 ms   <1 ms   <1 ms  192.168.1.1");
        con.writeLine("  2    *        *        *     Request timed out.");
    }

    fn cmdRunas(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: RUNAS [/profile] [/env] [/user] program [arguments]");
            return;
        }
        _ = con.writeOutput("Running as different user: ");
        con.writeLine(trimmed);
    }

    fn cmdMklink(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: MKLINK [[/D] | [/H] | [/J]] Link Target");
            return;
        }
        _ = con.writeOutput("Symbolic link created for ");
        con.writeLine(trimmed);
    }

    fn cmdCacls(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: CACLS filename [/T] [/E] [/G user:perm]");
            return;
        }
        _ = con.writeOutput("ACL for ");
        _ = con.writeOutput(trimmed);
        con.writeLine(":");
        con.writeLine("  NT AUTHORITY\\SYSTEM:(OI)(CI)(F)");
        con.writeLine("  BUILTIN\\Administrators:(OI)(CI)(F)");
    }

    fn cmdChkntfs(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("The type of the file system is FAT32.");
        con.writeLine("C: is clean.");
    }

    fn cmdCipher(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: CIPHER [/e | /d] [/s:dir] [filename ...]");
            return;
        }
        _ = con.writeOutput("Cipher operation on ");
        _ = con.writeOutput(trimmed);
        con.writeLine(" completed.");
    }

    fn cmdCompact(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: COMPACT [/c | /u] [/s[:dir]] [filename ...]");
            return;
        }
        _ = con.writeOutput("Compact operation on ");
        _ = con.writeOutput(trimmed);
        con.writeLine(" completed.");
    }

    fn cmdDefrag(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Defragmenting C:...");
        con.writeLine("Defragmentation complete.");
    }

    fn cmdFormat(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: FORMAT volume [/FS:file-system] [/V:label] [/Q]");
            return;
        }
        _ = con.writeOutput("Formatting ");
        _ = con.writeOutput(trimmed);
        con.writeLine("...");
        con.writeLine("Format complete.");
    }

    fn cmdFsutil(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: FSUTIL [behavior | dirty | file | fsinfo | hardlink | objectid | quota | reparsepoint | sparse | usn | volume]");
            return;
        }
        _ = con.writeOutput("FSUTIL: ");
        con.writeLine(trimmed);
    }

    fn cmdFtype(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine(".txt=txtfile");
            con.writeLine(".exe=exefile");
            return;
        }
        _ = con.writeOutput("File type association for ");
        _ = con.writeOutput(trimmed);
        con.writeLine(" displayed.");
    }

    fn cmdMode(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Status for device CON:");
            con.writeLine("    Lines:          300");
            con.writeLine("    Columns:        120");
            return;
        }
        _ = con.writeOutput("Device mode set to: ");
        con.writeLine(trimmed);
    }

    fn cmdMountvol(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Volume mount points:");
        con.writeLine("  \\??\\Volume{12345678-1234-1234-1234-123456789012}");
        con.writeLine("    C:");
    }

    fn cmdPrint(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: PRINT [/D:device] [drive:][path]filename[...]");
            return;
        }
        _ = con.writeOutput("Printing ");
        _ = con.writeOutput(trimmed);
        con.writeLine("...");
    }

    fn cmdRecover(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: RECOVER [drive:][path]filename");
            return;
        }
        _ = con.writeOutput("Recovering ");
        _ = con.writeOutput(trimmed);
        con.writeLine("...");
    }

    fn cmdReplace(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: REPLACE [drive1:][path1]filename [drive2:][path2] [/A] [/P] [/R] [/W] [/N]");
            return;
        }
        _ = con.writeOutput("Replacing ");
        con.writeLine(trimmed);
    }

    fn cmdRoute(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("IPv4 Route Table");
            con.writeLine("Active Routes:");
            con.writeLine("Network Destination        Netmask          Gateway       Metric");
            con.writeLine("          0.0.0.0          0.0.0.0      192.168.1.1       1");
            con.writeLine("        127.0.0.0        255.0.0.0        On-link         1");
            return;
        }
        _ = con.writeOutput("Route command: ");
        con.writeLine(trimmed);
    }

    fn cmdSchtasks(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: SCHTASKS [/CREATE | /DELETE | /QUERY | /RUN | /END | /CHANGE]");
            return;
        }
        _ = con.writeOutput("Scheduled task operation: ");
        con.writeLine(trimmed);
    }

    fn cmdSfc(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Beginning system scan.  This process will take some time.");
        con.writeLine("Windows Resource Protection did not find any integrity violations.");
    }

    fn cmdSetx(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: SETX [/S system [/U [username]]] variable value");
            return;
        }
        _ = con.writeOutput("Environment variable set permanently: ");
        con.writeLine(trimmed);
    }

    fn cmdTakeown(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: TAKEOWN [/s system] [/u username] [/f filename]");
            return;
        }
        _ = con.writeOutput("Ownership taken for: ");
        con.writeLine(trimmed);
    }

    fn cmdTelnet(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: TELNET [host [port]]");
            return;
        }
        _ = con.writeOutput("Connecting to ");
        _ = con.writeOutput(trimmed);
        con.writeLine("...");
        con.writeLine("Connection refused.");
    }

    fn cmdTftp(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: TFTP [-i] host [GET | PUT] source [target]");
            return;
        }
        _ = con.writeOutput("TFTP operation on ");
        _ = con.writeOutput(trimmed);
        con.writeLine(" completed.");
    }

    fn cmdWmic(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: WMIC [global switches] <command>");
            return;
        }
        if (std.mem.indexOf(u8, trimmed, "cpu") != null) {
            con.writeLine("Caption       MaxClockSpeed  Name");
            con.writeLine("ZirconOS64    2400           Zircon CPU");
            return;
        }
        _ = con.writeOutput("WMIC: ");
        con.writeLine(trimmed);
    }

    fn cmdWinmgmt(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("WMI service is running.");
    }

    fn cmdAssoc(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine(".txt=txtfile");
            con.writeLine(".exe=exefile");
            con.writeLine(".bat=batfile");
            con.writeLine(".cmd=cmdfile");
            con.writeLine(".sys=systemfile");
            return;
        }
        var dot_ext: [8]u8 = undefined;
        var ext_len: usize = 0;
        var j: usize = 0;
        while (j < trimmed.len and trimmed[j] != '=' and ext_len < dot_ext.len) : (j += 1) {
            dot_ext[ext_len] = trimmed[j];
            ext_len += 1;
        }
        _ = con.writeOutput("File association not found for extension ");
        _ = con.writeOutput(dot_ext[0..ext_len]);
        con.writeLine("");
    }

    fn cmdBcdedit(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0 or strEqlI(trimmed, "/enum")) {
            con.writeLine("Windows Boot Manager");
            con.writeLine("--------------------");
            con.writeLine("identifier              {bootmgr}");
            con.writeLine("device                  partition=\\Device\\HarddiskVolume1");
            con.writeLine("path                    \\EFI\\Microsoft\\Boot\\bootmgfw.efi");
            con.writeLine("description             Windows Boot Manager");
            con.writeLine("default                 {default}");
            return;
        }
        con.writeLine("The boot configuration data store could not be opened.");
    }

    fn cmdBreak(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Break is OFF.");
    }

    fn cmdChcp(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Active code page: 936");
    }

    fn cmdCmdkey(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Currently stored credentials:");
            return;
        }
        con.writeLine("CMDKEY: Credential added successfully.");
    }

    fn cmdComp(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Name of first file to compare:");
            return;
        }
        con.writeLine("The system cannot find the file specified.");
    }

    fn cmdConvert(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("The syntax of the command is incorrect.");
            return;
        }
        con.writeLine("Convert is not available for FAT32 volumes.");
    }

    fn cmdCscript(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: CScript scriptname.extension [option...] [script...]");
            return;
        }
        _ = con.writeOutput("Script host could not load the script: ");
        _ = con.writeOutput(trimmed);
        con.writeLine("");
    }

    fn cmdDoskey(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Command history:");
            if (self.history_count == 0) {
                con.writeLine("  (no history)");
                return;
            }
            var i: usize = 0;
            while (i < self.history_count) : (i += 1) {
                _ = con.writeOutput("  ");
                _ = con.writeOutput(self.history[i][0..self.history_len[i]]);
                con.writeLine("");
            }
            return;
        }
        con.writeLine("DOSKEY: macro defined.");
    }

    fn cmdDriverquery(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Module Name   Display Name           Driver Type   Start Mode");
        con.writeLine("============ ====================== ============= =============");
        con.writeLine("acpi.sys     Microsoft ACPI Driver  Kernel        System");
        con.writeLine("disk.sys     Disk Driver            Kernel        Boot");
        con.writeLine("partmgr.sys  Partition Manager      Kernel        Boot");
        con.writeLine("classpnp.sys SCSI Class Driver       Kernel        Boot");
        con.writeLine("vioscsi.sys  VirtIO SCSI Driver      Kernel        Boot");
    }

    fn cmdEventcreate(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("ERROR: Invalid argument/option");
            return;
        }
        con.writeLine("SUCCESS: The event log entry was created.");
    }

    fn cmdExpand(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("EXPAND expands one or more compressed files.");
            return;
        }
        _ = con.writeOutput("The system cannot find the file specified: ");
        _ = con.writeOutput(trimmed);
        con.writeLine("");
    }

    fn cmdExplorer(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Opening Windows Explorer...");
            return;
        }
        _ = con.writeOutput("Exploring: ");
        _ = con.writeOutput(trimmed);
        con.writeLine("");
    }

    fn cmdFindstr(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: FINDSTR [/S] [/I] string [filename]");
            return;
        }
        // FINDSTR pattern file → search file content
        const vol = fat32.getVolume();
        var pattern: []const u8 = trimmed;
        var filename: []const u8 = "";
        if (findFirstSpace(trimmed)) |sp| {
            pattern = trimmed[0..sp];
            filename = trimmed[sp + 1 ..];
        }
        if (filename.len == 0) {
            con.writeLine("FINDSTR: Cannot open file.");
            return;
        }
        const entry = vol.findEntry(filename) orelse {
            _ = con.writeOutput("FINDSTR: Cannot open file ");
            _ = con.writeOutput(filename);
            con.writeLine("");
            return;
        };
        var content_buf: [8192]u8 = undefined;
        const cluster = entry.getFirstCluster();
        const content_len = vol.readData(cluster, &content_buf);
        const content = content_buf[0..content_len];
        var found: usize = 0;
        var line_start: usize = 0;
        for (content, 0..) |c, i| {
            if (c != '\n') continue;
            const line = content[line_start..i];
            if (containsSubstrI(line, pattern)) {
                found += 1;
                _ = con.writeOutput(filename);
                _ = con.writeOutput(":");
                _ = con.writeOutput(line);
                con.writeLine("");
            }
            line_start = i + 1;
        }
        if (found == 0) {
            _ = con.writeOutput("FINDSTR: No matches found in ");
            _ = con.writeOutput(filename);
            con.writeLine("");
        }
    }

    fn cmdForfiles(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("FORFILES [/P Path] [/M SearchMask] [/C Command]");
            return;
        }
        con.writeLine("ERROR: Invalid syntax.");
    }

    fn cmdGoto(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("The system cannot find the label specified.");
            return;
        }
        _ = con.writeOutput("The system cannot find the label: ");
        _ = con.writeOutput(trimmed);
        con.writeLine("");
    }

    fn cmdGpresult(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Microsoft (R) Windows Group Policy results:");
        con.writeLine("=========================================");
        con.writeLine("Applied Group Policy objects:");
        con.writeLine("  (no policy objects applied)");
    }

    fn cmdIcacls(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: ICACLS filename [/T] [/C] [/Grant[:r] name:perm]");
            return;
        }
        _ = con.writeOutput(trimmed);
        con.writeLine(" NT AUTHORITY\\SYSTEM:(I)(F)");
        con.writeLine("        BUILTIN\\Administrators:(I)(F)");
        con.writeLine("        BUILTIN\\Users:(I)(M)");
    }

    fn cmdLogoff(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Logoff is not available in this session.");
    }

    fn cmdMstsc(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Remote Desktop Connection");
            con.writeLine("Usage: mstsc [ComputerName]");
            return;
        }
        _ = con.writeOutput("Connecting to: ");
        _ = con.writeOutput(trimmed);
        con.writeLine("");
        con.writeLine("Connection failed: The system cannot connect.");
    }

    fn cmdNetsh(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: netsh [context] [command]");
            con.writeLine("Available contexts: interface, ip, wlan, advfirewall");
            return;
        }
        if (strEqlI(trimmed, "interface show interface")) {
            con.writeLine("Admin State  State  Type  Interface Name");
            con.writeLine("---------  -----  ----  --------------");
            con.writeLine("Enabled    Connected  Loopback  Loopback Pseudo-Interface 1");
            return;
        }
        con.writeLine("The following command was not found: netsh.");
    }

    fn cmdOpenfiles(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("INFO: The system global flag 'maintain objects list' needs");
            con.writeLine("to be enabled to see local open files.");
            return;
        }
        con.writeLine("No open files found.");
    }

    fn cmdPathping(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: pathping [-n] [-g] [-h] target_name");
            return;
        }
        _ = con.writeOutput("Tracing route to ");
        _ = con.writeOutput(trimmed);
        con.writeLine(" over a maximum of 30 hops:");
        con.writeLine("Trace complete.");
    }

    fn cmdPrompt(_: *CmdShell, _: []const u8) void {}

    fn cmdSetlocal(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Local environment changes started.");
    }

    fn cmdEndlocal(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Local environment changes ended.");
    }

    fn cmdGetmac(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine("Physical Address    Transport Name");
        con.writeLine("=====================================================");
        con.writeLine("52-54-00-12-34-56   \\Device\\Tcpip_{4B2A1B0A-0000-4E11-9C33-0A0A0A0A0A0A}");
        con.writeLine("");
    }

    fn cmdGpupdate(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Updating policy...");
        con.writeLine("");
        con.writeLine("Computer Policy update has completed successfully.");
        con.writeLine("User Policy update has completed successfully.");
    }

    fn cmdMsconfig(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("System Configuration utility is not available in this console session.");
    }

    fn cmdMsinfo32(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("System Information");
        con.writeLine("==================");
        con.writeLine("OS Name: ZirconOSAero (NT 6.1 compatible)");
        con.writeLine("System Type: kernel-mode hybrid system");
    }

    fn cmdNlsfunc(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("NLSFUNC [filename]");
            return;
        }
        con.writeLine("National Language Support functions loaded.");
    }

    fn cmdShift(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("SHIFT: no more parameters.");
    }

    fn cmdTimeout(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("TIMEOUT [/T] timeout");
            return;
        }
        _ = con.writeOutput("Waiting for ");
        _ = con.writeOutput(trimmed);
        con.writeLine(" seconds, press a key to continue ...");
    }

    fn cmdTskill(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: tskill <ProcessId | ProcessName>");
            return;
        }
        _ = con.writeOutput("Could not find process: ");
        _ = con.writeOutput(trimmed);
        con.writeLine("");
    }

    fn cmdTypeperf(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: typeperf <counter [counter ...]>");
            return;
        }
        con.writeLine("Error: counter not found.");
    }

    fn cmdVssadmin(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0 or strEqlI(trimmed, "list volumes")) {
            con.writeLine("vssadmin: no shadow copies found.");
            return;
        }
        con.writeLine("vssadmin: command not recognized.");
    }

    fn cmdW32tm(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0 or strEqlI(trimmed, "/status")) {
            con.writeLine("Windows Time Service is running.");
            return;
        }
        con.writeLine("W32TM: command not recognized.");
    }

    fn cmdWaitfor(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: waitfor [/t <timeout>] <signal>");
            return;
        }
        con.writeLine("Error: waitfor timed out.");
    }

    fn addHistory(self: *CmdShell, cmd: []const u8) void {
        if (self.history_count >= MAX_HISTORY) return;
        const copy_len = @min(cmd.len, MAX_CMD_LEN);
        @memcpy(self.history[self.history_count][0..copy_len], cmd[0..copy_len]);
        self.history_len[self.history_count] = copy_len;
        self.history_count += 1;
    }

    fn cmdClip(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdClip(self, args);
    }
    fn cmdEdit(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdEdit(self, args);
    }
    fn cmdEventquery(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdEventquery(self, args);
    }
    fn cmdFor(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdFor(self, args);
    }
    fn cmdIf(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdIf(self, args);
    }
    fn cmdInuse(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdInuse(self, args);
    }
    fn cmdKlist(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdKlist(self, args);
    }
    fn cmdKsetup(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdKsetup(self, args);
    }
    fn cmdLodctr(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdLodctr(self, args);
    }
    fn cmdLogman(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdLogman(self, args);
    }
    fn cmdLpq(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdLpq(self, args);
    }
    fn cmdLpr(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdLpr(self, args);
    }
    fn cmdMsiexec(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdMsiexec(self, args);
    }
    fn cmdNetcfg(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdNetcfg(self, args);
    }
    fn cmdNtsd(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdNtsd(self, args);
    }
    fn cmdOcsetup(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdOcsetup(self, args);
    }
    fn cmdPerfmon(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdPerfmon(self, args);
    }
    fn cmdPowercfg(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdPowercfg(self, args);
    }
    fn cmdPsr(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdPsr(self, args);
    }
    fn cmdRasdial(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdRasdial(self, args);
    }
    fn cmdRcp(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdRcp(self, args);
    }
    fn cmdRegini(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdRegini(self, args);
    }
    fn cmdRegsvr32(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdRegsvr32(self, args);
    }
    fn cmdRexec(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdRexec(self, args);
    }
    fn cmdRpcping(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdRpcping(self, args);
    }
    fn cmdRsh(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdRsh(self, args);
    }
    fn cmdRwinsta(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdRwinsta(self, args);
    }
    fn cmdTcmsetup(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdTcmsetup(self, args);
    }
    fn cmdUnlodctr(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdUnlodctr(self, args);
    }
    fn cmdVerifier(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdVerifier(self, args);
    }

    fn cmdBitsadmin(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdBitsadmin(self, args);
    }
    fn cmdBootcfg(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdBootcfg(self, args);
    }
    fn cmdCertreq(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdCertreq(self, args);
    }
    fn cmdCertutil(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdCertutil(self, args);
    }
    fn cmdChoice(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdChoice(self, args);
    }
    fn cmdNestedCmd(self: *CmdShell) void {
        extra_cmds.cmdNestedCmd(self);
    }
    fn cmdDism(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdDism(self, args);
    }
    fn cmdDvdplay(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdDvdplay(self, args);
    }
    fn cmdEventvwr(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdEventvwr(self, args);
    }
    fn cmdFltmc(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdFltmc(self, args);
    }
    fn cmdIexpress(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdIexpress(self, args);
    }
    fn cmdMakecab(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdMakecab(self, args);
    }
    fn cmdMsg(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdMsg(self, args);
    }
    fn cmdNbtstat(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdNbtstat(self, args);
    }
    fn cmdQprocess(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdQprocess(self, args);
    }
    fn cmdQuery(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdQuery(self, args);
    }
    fn cmdQuser(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdQuser(self, args);
    }
    fn cmdQwinsta(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdQwinsta(self, args);
    }
    fn cmdReset(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdReset(self, args);
    }
    fn cmdSxstrace(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdSxstrace(self, args);
    }
    fn cmdWinrs(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdWinrs(self, args);
    }
    fn cmdWscript(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdWscript(self, args);
    }
    fn cmdXwizard(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdXwizard(self, args);
    }
    fn cmdDsacls(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdDsacls(self, args);
    }
    fn cmdDsadd(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdDsadd(self, args);
    }
    fn cmdDsget(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdDsget(self, args);
    }
    fn cmdDsmod(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdDsmod(self, args);
    }
    fn cmdDsmove(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdDsmove(self, args);
    }
    fn cmdDsquery(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdDsquery(self, args);
    }
    fn cmdFlattemp(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdFlattemp(self, args);
    }
    fn cmdChgport(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdChgport(self, args);
    }
    fn cmdChgusr(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdChgusr(self, args);
    }
    fn cmdCmstp(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdCmstp(self, args);
    }
    fn cmdEventtriggers(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdEventtriggers(self, args);
    }
    fn cmdIpxroute(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdIpxroute(self, args);
    }
    fn cmdMapadmin(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdMapadmin(self, args);
    }
    fn cmdNfsadmin(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdNfsadmin(self, args);
    }
    fn cmdPrncnfg(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdPrncnfg(self, args);
    }
    fn cmdPrndrvr(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdPrndrvr(self, args);
    }
    fn cmdPrnjobs(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdPrnjobs(self, args);
    }
    fn cmdPrnmngr(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdPrnmngr(self, args);
    }
    fn cmdPrnport(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdPrnport(self, args);
    }
    fn cmdPrnqctl(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdPrnqctl(self, args);
    }
    fn cmdPentnt(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdPentnt(self, args);
    }
    fn cmdArp(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdArp(self, args);
    }
    fn cmdAt(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdAt(self, args);
    }
    fn cmdCall(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdCall(self, args);
    }
    fn cmdDispdiag(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdDispdiag(self, args);
    }
    fn cmdNltest(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdNltest(self, args);
    }
    fn cmdQappsrv(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdQappsrv(self, args);
    }
    fn cmdTscon(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdTscon(self, args);
    }
    fn cmdTsdiscon(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdTsdiscon(self, args);
    }
    fn cmdDelprof(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdDelprof(self, args);
    }
    fn cmdFreedisk(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdFreedisk(self, args);
    }
    fn cmdAuditpol(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdAuditpol(self, args);
    }
    fn cmdChange(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdChange(self, args);
    }
    fn cmdNtbackup(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdNtbackup(self, args);
    }
    fn cmdSecedit(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdSecedit(self, args);
    }
    fn cmdDxdiag(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdDxdiag(self, args);
    }
    fn cmdWinsat(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdWinsat(self, args);
    }
    fn cmdMsra(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdMsra(self, args);
    }
    fn cmdSlmgr(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdSlmgr(self, args);
    }
    fn cmdSdbinst(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdSdbinst(self, args);
    }
    fn cmdSigverif(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdSigverif(self, args);
    }
    fn cmdWuauclt(self: *CmdShell, args: []const u8) void {
        extra_cmds.cmdWuauclt(self, args);
    }
};

// ── Global CMD instance ──

var cmd_shell: CmdShell = .{};
var cmd_initialized: bool = false;

pub fn init() void {
    cmd_shell.init();
    cmd_initialized = true;
    klog.info("CMD: Command shell initialized", .{});
}

pub fn getShell() *CmdShell {
    return &cmd_shell;
}

pub fn runBootSequence() void {
    if (!cmd_initialized) init();

    cmd_shell.showBanner();
    cmd_shell.showPrompt();

    const demo_commands = [_][]const u8{
        "ver",
        "systeminfo",
        "dir",
        "set",
    };

    for (demo_commands) |cmd_str| {
        const con = console.getConsole(cmd_shell.console_id);
        if (con) |c| {
            _ = c.writeOutput(cmd_str);
            c.writeLine("");
        }
        cmd_shell.executeCommand(cmd_str);
        cmd_shell.showPrompt();
    }
}

pub fn runInteractiveShell() noreturn {
    const arch = @import("../../arch.zig");

    if (!cmd_initialized) init();

    cmd_shell.showBanner();
    cmd_shell.showPrompt();

    var line_buf: [MAX_CMD_LEN]u8 = undefined;
    var line_len: usize = 0;

    while (true) {
        const ch_opt = arch.readInputChar();
        if (ch_opt) |ch| {
            switch (ch) {
                '\n', '\r' => {
                    const con = console.getConsole(cmd_shell.console_id);
                    if (con) |c| {
                        c.writeLine("");
                    }
                    if (line_len > 0) {
                        cmd_shell.executeCommand(line_buf[0..line_len]);
                    }
                    if (cmd_shell.state == .exiting) {
                        cmd_shell.state = .running;
                        klog.info("CMD: Restarting shell after exit", .{});
                    }
                    cmd_shell.showPrompt();
                    line_len = 0;
                },
                0x08, 0x7F => {
                    if (line_len > 0) {
                        line_len -= 1;
                        const con = console.getConsole(cmd_shell.console_id);
                        if (con) |c| {
                            _ = c.writeOutput("\x08 \x08");
                        }
                    }
                },
                0x03 => {
                    const con = console.getConsole(cmd_shell.console_id);
                    if (con) |c| {
                        c.writeLine("^C");
                    }
                    line_len = 0;
                    cmd_shell.showPrompt();
                },
                else => {
                    if (ch >= 0x20 and ch < 0x7F and line_len < MAX_CMD_LEN - 1) {
                        line_buf[line_len] = ch;
                        line_len += 1;
                        const con = console.getConsole(cmd_shell.console_id);
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
    return cmd_initialized;
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

fn findFirstSpace(s: []const u8) ?usize {
    for (s, 0..) |c, i| {
        if (c == ' ' or c == '\t') return i;
    }
    return null;
}

const SystemTool = struct {
    name: []const u8,
    display_name: []const u8,
};

const system_tools = [_]SystemTool{
    .{ .name = "adprep", .display_name = "ADPREP" },
    .{ .name = "append", .display_name = "APPEND" },
    .{ .name = "atmadm", .display_name = "ATMADM" },
    .{ .name = "audtipol", .display_name = "AUDTIPOL" },
    .{ .name = "autochk", .display_name = "AUTOCHK" },
    .{ .name = "autoconv", .display_name = "AUTOCONV" },
    .{ .name = "autofmt", .display_name = "AUTOFMT" },
    .{ .name = "automount", .display_name = "AUTOMOUNT" },
    .{ .name = "bcdboot", .display_name = "BCDBOOT" },
    .{ .name = "chglogon", .display_name = "CHGLOGON" },
    .{ .name = "clean", .display_name = "CLEAN" },
    .{ .name = "cluster", .display_name = "CLUSTER" },
    .{ .name = "cprofile", .display_name = "CPROFILE" },
    .{ .name = "csvde", .display_name = "CSVDE" },
    .{ .name = "dcdiag", .display_name = "DCDIAG" },
    .{ .name = "dcpromo", .display_name = "DCPROMO" },
    .{ .name = "dfscmd", .display_name = "DFSCMD" },
    .{ .name = "dirquota", .display_name = "DIRQUOTA" },
    .{ .name = "diskcomp", .display_name = "DISKCOMP" },
    .{ .name = "diskcopy", .display_name = "DISKCOPY" },
    .{ .name = "diskedit", .display_name = "DISKEDIT" },
    .{ .name = "diskraid", .display_name = "DISKRAID" },
    .{ .name = "diskshadow", .display_name = "DISKSHADOW" },
    .{ .name = "djoin", .display_name = "DJOIN" },
    .{ .name = "dnscmd", .display_name = "DNSCMD" },
    .{ .name = "ds", .display_name = "DS" },
    .{ .name = "dsamain", .display_name = "DSAMAIN" },
    .{ .name = "dsdbutil", .display_name = "DSDBUTIL" },
    .{ .name = "dsmgmt", .display_name = "DSMGMT" },
    .{ .name = "dsrm", .display_name = "DSRM" },
    .{ .name = "filescrn", .display_name = "FILESCRN" },
    .{ .name = "filesystems", .display_name = "FILESYSTEMS" },
    .{ .name = "finger", .display_name = "FINGER" },
    .{ .name = "ftp", .display_name = "FTP" },
    .{ .name = "gettype", .display_name = "GETTYPE" },
    .{ .name = "helpctr", .display_name = "HELPCTR" },
    .{ .name = "ifm", .display_name = "IFM" },
    .{ .name = "irftp", .display_name = "IRFTP" },
    .{ .name = "ismserv", .display_name = "ISMSERV" },
    .{ .name = "ktmutil", .display_name = "KTMUTIL" },
    .{ .name = "ktpass", .display_name = "KTPASS" },
    .{ .name = "ldap", .display_name = "LDAP" },
    .{ .name = "ldifde", .display_name = "LDIFDE" },
    .{ .name = "ldp", .display_name = "LDP" },
    .{ .name = "macfile", .display_name = "MACFILE" },
    .{ .name = "mount", .display_name = "MOUNT" },
    .{ .name = "netdiag", .display_name = "NETDIAG" },
    .{ .name = "netdom", .display_name = "NETDOM" },
    .{ .name = "nfsshare", .display_name = "NFSSHARE" },
    .{ .name = "nfsstat", .display_name = "NFSSTAT" },
    .{ .name = "nlb", .display_name = "NLB" },
    .{ .name = "ntdsutil", .display_name = "NTDSUTIL" },
    .{ .name = "pagefileconfig.vbs", .display_name = "PAGEFILECONFIG" },
    .{ .name = "pnputil", .display_name = "PNPUTIL" },
    .{ .name = "pubprn.vbs", .display_name = "PUBPRN" },
    .{ .name = "rdpsign", .display_name = "RDPSIGN" },
    .{ .name = "reagentc", .display_name = "REAGENTC" },
    .{ .name = "redircmp", .display_name = "REDIRCMP" },
    .{ .name = "redirusr", .display_name = "REDIRUSR" },
    .{ .name = "repadmin", .display_name = "REPADMIN" },
    .{ .name = "rescan", .display_name = "RESCAN" },
    .{ .name = "retain", .display_name = "RETAIN" },
    .{ .name = "rpcinfo", .display_name = "RPCINFO" },
    .{ .name = "services", .display_name = "SERVICES" },
    .{ .name = "setid", .display_name = "SETID" },
    .{ .name = "setspn", .display_name = "SETSPN" },
    .{ .name = "shadow", .display_name = "SHADOW" },
    .{ .name = "showmount", .display_name = "SHOWMOUNT" },
    .{ .name = "shrink", .display_name = "SHRINK" },
    .{ .name = "storrept", .display_name = "STORREPT" },
    .{ .name = "sysocmgr", .display_name = "SYSOCMGR" },
    .{ .name = "tapicfg", .display_name = "TAPICFG" },
    .{ .name = "tlntadmn", .display_name = "TLNTADMN" },
    .{ .name = "tsecimp", .display_name = "TSECIMP" },
    .{ .name = "tsprof", .display_name = "TSPROF" },
    .{ .name = "uddiconfig", .display_name = "UDDICONFIG" },
    .{ .name = "umount", .display_name = "UMOUNT" },
    .{ .name = "uniqueid", .display_name = "UNIQUEID" },
    .{ .name = "wbadmin", .display_name = "WBADMIN" },
    .{ .name = "wdsutil", .display_name = "WDSUTIL" },
    .{ .name = "wecutil", .display_name = "WECUTIL" },
    .{ .name = "wevtutil", .display_name = "WEVTUTIL" },
    .{ .name = "winnt", .display_name = "WINNT" },
    .{ .name = "winpop", .display_name = "WINPOP" },
};

fn systemToolByName(input: []const u8) ?SystemTool {
    for (system_tools) |tool| {
        if (strEqlI(input, tool.name)) return tool;
    }
    return null;
}

fn containsSubstrI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            const hc = haystack[i + j];
            const nc = needle[j];
            if (hc != nc and hc != nc + 32 and hc + 32 != nc) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) start += 1;
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r' or s[end - 1] == '\n')) end -= 1;
    return s[start..end];
}

fn formatUintPad2(buf: []u8, value: usize) []const u8 {
    if (buf.len < 2) return buf[0..0];
    if (value < 10) {
        buf[0] = '0';
        buf[1] = '0' + @as(u8, @intCast(value));
        return buf[0..2];
    }
    return formatUint(buf, value);
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

const extra_cmds = struct {
    fn cmdClip(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("ZirconOS clipboard: 0 bytes.");
    }

    fn cmdEdit(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("ZirconOS Editor v1.0 — text editing requires the desktop shell.");
    }

    fn cmdEventquery(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("No events match the specified criteria.");
    }

    fn cmdFor(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        if (args.len == 0) {
            con.writeLine("FOR: loops over a set of items.");
            con.writeLine("FOR %variable IN (set) DO command [parameters]");
        } else {
            con.writeLine("FOR batch loops are not supported in this session.");
        }
    }

    fn cmdIf(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("IF batch conditionals are not supported in this session.");
    }

    fn cmdInuse(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("The file or directory is not in use.");
    }

    fn cmdKlist(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("Current LogonId is 0:0x3e7");
        con.writeLine("Cached Tickets: (0)");
    }

    fn cmdKsetup(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("Kerberos realm: (not set)");
    }

    fn cmdLodctr(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        if (args.len == 0) {
            con.writeLine("LODCTR: Registers new Performance counter names and Explain text.");
        } else {
            con.writeLine("Counter registry entries loaded successfully.");
        }
    }

    fn cmdLogman(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("No data collector sets are defined.");
    }

    fn cmdLpq(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("LPQ: No printer jobs queued.");
    }

    fn cmdLpr(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("LPR: Print job submitted.");
    }

    fn cmdMsiexec(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("Windows Installer 5.0.7601.17514");
    }

    fn cmdNetcfg(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("NetCfg: Network configuration complete.");
    }

    fn cmdNtsd(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("NTSD: Debugger session ended.");
    }

    fn cmdOcsetup(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("OCSetup: Optional component installation complete.");
    }

    fn cmdPerfmon(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("Performance Monitor requires the desktop shell.");
    }

    fn cmdPowercfg(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("The following power schemes are available:");
        con.writeLine("  381b4222-f694-41f0-868f-e4b7a9d76c44  Balanced");
        con.writeLine("  8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  High performance");
        con.writeLine("  a1841308-7741-4e40-9338-4a8e5b0e8f2b  Power saver");
    }

    fn cmdPsr(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("Problem Steps Recorder requires the desktop shell.");
    }

    fn cmdRasdial(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("No remote access connections are available.");
    }

    fn cmdRcp(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("RCP: No remote copy hosts configured.");
    }

    fn cmdRegini(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("Registry script processing complete.");
    }

    fn cmdRegsvr32(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("DllRegisterServer succeeded.");
    }

    fn cmdRexec(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("REXEC: Connection refused.");
    }

    fn cmdRpcping(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("RPC ping complete (0 ms).");
    }

    fn cmdRsh(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("RSH: Connection refused.");
    }

    fn cmdRwinsta(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("No remote sessions found.");
    }

    fn cmdTcmsetup(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("Telephony client setup complete.");
    }

    fn cmdUnlodctr(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        if (args.len == 0) {
            con.writeLine("UNLODCTR: Removes Performance counter names and Explain text.");
        } else {
            con.writeLine("Counter registry entries removed successfully.");
        }
    }

    fn cmdVerifier(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("Driver Verifier is not active.");
    }

    fn cmdBitsadmin(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0 or strEqlI(trimmed, "/list")) {
            con.writeLine("BITSADMIN version 3.0");
            con.writeLine("Job list:");
            con.writeLine("(no jobs)");
            return;
        }
        _ = con.writeOutput("BITSADMIN: unsupported operation: ");
        _ = con.writeOutput(trimmed);
        con.writeLine("");
    }

    fn cmdBootcfg(self: *CmdShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Boot loader settings");
        con.writeLine("--------------------");
        con.writeLine("identifier           {bootmgr}");
        con.writeLine("device               boot");
        con.writeLine("timeout              10");
    }

    fn cmdCertreq(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: CertReq [-Submit] [RequestFileIn [CertFileOut [ChainFileOut]]]");
            return;
        }
        con.writeLine("CertReq: The request file was not found.");
    }

    fn cmdCertutil(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("CertUtil: Usage: certutil [verb] [options]");
            return;
        }
        con.writeLine("CertUtil: command completed successfully.");
    }

    fn cmdChoice(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = con.writeOutput("[");
        _ = con.writeOutput(if (args.len > 0) args else "Y,N");
        con.writeLine("]? N");
    }

    fn cmdNestedCmd(self: *CmdShell) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Microsoft Windows [Version 6.1.7601]");
        con.writeLine("Nested cmd.exe sessions are not supported by this console.");
    }

    fn cmdDism(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("DISM: Usage: DISM.exe [/?] [/Online] [/Cleanup-Image] [/Help]");
            return;
        }
        con.writeLine("DISM: The operation is not supported on this installation.");
    }

    fn cmdDvdplay(self: *CmdShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("DVD Player: No DVD drive detected.");
    }

    fn cmdEventvwr(self: *CmdShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Event Viewer: No event logs are currently open.");
    }

    fn cmdFltmc(self: *CmdShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Filter list:");
        con.writeLine("  No filter objects are loaded.");
    }

    fn cmdIexpress(self: *CmdShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("IExpress: Self-extraction package wizard is unavailable.");
    }

    fn cmdMakecab(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: MAKECAB [/V[n] | /L Dir] Source [Destination]");
            return;
        }
        _ = con.writeOutput("MAKECAB: Cannot open input file: ");
        _ = con.writeOutput(trimmed);
        con.writeLine("");
    }

    fn cmdMsg(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("MSG {username | sessionname | sessionid} [/SERVER:server] message");
            return;
        }
        con.writeLine("MSG: Error 1722 getting session names.");
    }

    fn cmdNbtstat(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Usage: NBTSTAT [-a Adapter] [-n] [-r] [-R] [-S] [-s] [interval]");
            return;
        }
        con.writeLine("Node IpAddress: 0.0.0.0");
        con.writeLine("NetBIOS names are not available.");
    }

    fn cmdQprocess(self: *CmdShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("USERNAME    SESSIONNAME  PID  IMAGE");
        con.writeLine("==========  ===========  ===  =====");
        con.writeLine("SYSTEM      Console        1  System");
    }

    fn cmdQuery(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (strEqlI(trimmed, "user")) {
            self.cmdQuser(args);
        } else if (strEqlI(trimmed, "process")) {
            self.cmdQprocess(args);
        } else {
            con.writeLine("Query: Supported objects are user and process.");
        }
    }

    fn cmdQuser(self: *CmdShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("USERNAME   SESSIONNAME    ID  STATE   IDLE  LOGONTIME");
        con.writeLine("---------  -------------  --  ------  ----  ---------");
        con.writeLine("SYSTEM     Console         1  Active   none  (local)");
    }

    fn cmdQwinsta(self: *CmdShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine(" SESSIONNAME       USERNAME       ID  STATE   TYPE   DEVICE");
        con.writeLine(" console                          0  Conn    wdcon");
        con.writeLine(" rdp-tcp                        65536  Listen  rdpwd");
    }

    fn cmdReset(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (strEqlI(trimmed, "session")) {
            con.writeLine("Reset session: No disconnected sessions found.");
            return;
        }
        con.writeLine("RESET SESSION [sessionname | sessionid] [/V]");
    }

    fn cmdSxstrace(self: *CmdShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Side-by-side trace: no active trace log.");
    }

    fn cmdWinrs(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Windows Remote Shell");
            con.writeLine("Usage: winrs [/<option>][:<value>] <command>");
            return;
        }
        con.writeLine("WinRS: The remote shell service is unavailable.");
    }

    fn cmdWscript(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("Microsoft (R) Windows Script Host Version 5.8.7601.17514");
    }

    fn cmdXwizard(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("XWizard: Wizard not available.");
    }

    fn cmdDsacls(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("DSAcls: No directory service ACLs to display.");
    }

    fn cmdDsadd(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("DSAdd: No directory service objects to add.");
    }

    fn cmdDsget(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("DSGet: No directory service objects found.");
    }

    fn cmdDsmod(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("DSMod: No directory service objects to modify.");
    }

    fn cmdDsmove(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("DSMove: No directory service objects to move.");
    }

    fn cmdDsquery(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("DSQuery: No directory service objects found.");
    }

    fn cmdFlattemp(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("FlatTemp: Temporary directory is not flat.");
    }

    fn cmdChgport(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("No COM port mappings found.");
    }

    fn cmdChgusr(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("Change User mode: Execute.");
    }

    fn cmdCmstp(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("CMSTP: Connection Manager profile not found.");
    }

    fn cmdEventtriggers(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("No event triggers are defined.");
    }

    fn cmdIpxroute(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("IPX routing table is empty.");
    }

    fn cmdMapadmin(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("Microsoft Services for NFS: No mapping servers.");
    }

    fn cmdNfsadmin(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("Microsoft Services for NFS: Server not installed.");
    }

    fn cmdPrncnfg(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("No printers configured.");
    }

    fn cmdPrndrvr(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("No printer drivers installed.");
    }

    fn cmdPrnjobs(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("No print jobs queued.");
    }

    fn cmdPrnmngr(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("No printers installed.");
    }

    fn cmdPrnport(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("No printer ports configured.");
    }

    fn cmdPrnqctl(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("No printer queues found.");
    }

    fn cmdPentnt(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("Pentium FDIV bug: Not detected.");
    }

    fn cmdArp(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0 or strEqlI(trimmed, "-a")) {
            con.writeLine("");
            con.writeLine("Internet Address          Physical Address      Type");
            con.writeLine("  10.0.2.2                52-54-00-12-34-56     dynamic");
        } else if (strEqlI(trimmed, "-g") or strEqlI(trimmed, "/a")) {
            con.writeLine("");
            con.writeLine("Internet Address          Physical Address      Type");
            con.writeLine("  10.0.2.2                52-54-00-12-34-56     dynamic");
        } else {
            con.writeLine("ARP: entry added/deleted (stub).");
        }
    }

    fn cmdAt(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("Scheduled tasks: (none)");
        } else if (strEqlI(trimmed, "/delete")) {
            con.writeLine("Scheduled task deleted.");
        } else {
            con.writeLine("Scheduled task added (stub).");
        }
    }

    fn cmdCall(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("CALL: missing batch file name.");
        } else {
            con.writeLine("CALL: batch execution of );            _ = con.writeOutput(trimmed);            con.writeLine( not yet supported in kernel cmd.");
        }
    }

    fn cmdDispdiag(self: *CmdShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("DISPDIAG: display diagnostics data collected (stub).");
    }

    fn cmdNltest(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0 or strEqlI(trimmed, "/help")) {
            con.writeLine("NLTEST: /DSGETDC, /SC_QUERY, /LIST_TRUSTS, /DSADDR, /BDC_QUERY, /HELP");
        } else {
            con.writeLine("NLTEST: no domain controller configured (standalone).");
        }
    }

    fn cmdQappsrv(self: *CmdShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("No RemoteApp servers available.");
    }

    fn cmdTscon(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("TSCON: missing session ID or name.");
        } else {
            con.writeLine("TSCON: session connection not supported in kernel cmd (stub).");
        }
    }

    fn cmdTsdiscon(self: *CmdShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("TSDISCON: session disconnect not supported in kernel cmd (stub).");
    }

    fn cmdDelprof(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = args;
        con.writeLine("No user profiles found to delete.");
    }

    fn cmdFreedisk(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("FREEDISK: missing drive letter.");
            return;
        }
        con.writeLine("Drive C: 452,927,488 bytes free.");
    }

    fn cmdAuditpol(self: *CmdShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("Audit Policy: (no audit events configured)");
    }

    fn cmdChange(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0 or strEqlI(trimmed, "/help")) {
            con.writeLine("CHANGE: /LOG, /PORT, /USER");
        } else {
            con.writeLine("CHANGE: command not supported in kernel cmd (stub).");
        }
    }

    fn cmdNtbackup(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0 or strEqlI(trimmed, "/?")) {
            con.writeLine("NTBACKUP: Windows Backup utility.");
            con.writeLine("Usage: NTBACKUP BACKUP /J <job_name> [/F <file>] /T <tape> [/V {yes|no}]");
            con.writeLine("       NTBACKUP RESTORE /J <job_name> /T <tape>");
            return;
        }
        con.writeLine("NTBACKUP: backup operation started (no backup devices detected).");
    }

    fn cmdSecedit(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0 or strEqlI(trimmed, "/?")) {
            con.writeLine("SECEDIT: Security Configuration and Analysis.");
            con.writeLine("Usage: SECEDIT /ANALYZE /DB <database> /CFG <template>");
            con.writeLine("       SECEDIT /CONFIGURE /DB <database> /CFG <template>");
            con.writeLine("       SECEDIT /EXPORT /DB <database> /CFG <output_file>");
            return;
        }
        con.writeLine("SECEDIT: operation completed (security database is current).");
    }

    fn cmdDxdiag(self: *CmdShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("DirectX Diagnostic Tool");
        con.writeLine("DirectX Version: DirectX 11");
        con.writeLine("System Model: ZirconOSAero Virtual Machine");
        con.writeLine("Display Tab: No display problems found.");
    }

    fn cmdWinsat(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0 or strEqlI(trimmed, "/?")) {
            con.writeLine("WINSAT: Windows System Assessment Tool.");
            con.writeLine("Usage: WINSAT formal | cpu | mem | disk | d3d | aes");
            return;
        }
        if (strEqlI(trimmed, "formal")) {
            con.writeLine("WINSAT: formal assessment running...");
            con.writeLine("  CPU: 5.9  Memory: 5.9  Graphics: 4.2  Gaming: 4.2  Disk: 5.8");
            con.writeLine("WINSAT: Windows Experience Index = 4.2 (graphics limited).");
        } else {
            con.writeLine("WINSAT: sub-assessment completed.");
        }
    }

    fn cmdMsra(self: *CmdShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("MSRA: Remote Assistance invitation tool.");
        con.writeLine("Remote Assistance is not available in this environment.");
    }

    fn cmdSlmgr(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (strEqlI(trimmed, "/xpr") or strEqlI(trimmed, "-xpr")) {
            con.writeLine("Windows activation expires on 2026-12-31.");
        } else if (trimmed.len == 0 or strEqlI(trimmed, "/?")) {
            con.writeLine("SLMGR: Software License Manager.");
            con.writeLine("Usage: SLMGR /XPR | /DLI | /ATO");
        } else {
            con.writeLine("SLMGR: operation completed.");
        }
    }

    fn cmdSdbinst(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0) {
            con.writeLine("SDBINST: missing database file name.");
            return;
        }
        con.writeLine("SDBINST: application compatibility database installed.");
    }

    fn cmdSigverif(self: *CmdShell, _: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("File Signature Verification Tool");
        con.writeLine("All system files are digitally signed (Microsoft Windows Publisher).");
    }

    fn cmdWuauclt(self: *CmdShell, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const trimmed = trim(args);
        if (trimmed.len == 0 or strEqlI(trimmed, "/?")) {
            con.writeLine("WUAUCLT: Windows Update Agent.");
            con.writeLine("Usage: WUAUCLT /DETECTNOW | /REPORTNOW");
            return;
        }
        con.writeLine("WUAUCLT: update check initiated (no updates available).");
    }
};
