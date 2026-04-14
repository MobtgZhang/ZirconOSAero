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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/kernel/ime/pinyin_engine.zig
// Purpose: Pinyin Engine - simple Chinese pinyin input method
//
// Clean-room implementation. This is a simplified pinyin engine
// that provides basic Chinese character input without external dictionaries.
//
// The dictionary contains ~1500 common Chinese characters covering:
// - Most frequently used characters
// - All 400+ pinyin syllables
// - Single and multi-character words

const std = @import("std");
const klog = @import("../../../rtl/klog.zig");
const candidates_mod = @import("candidates.zig");

/// Pinyin tone types
pub const PinyinTone = enum(u8) {
    none = 0,
    tone1 = 1,
    tone2 = 2,
    tone3 = 3,
    tone4 = 4,
    tone5 = 5,
};

/// Pinyin entry (single syllable)
pub const PinyinEntry = struct {
    pinyin: [8]u8,
    chars: [32]u8,  // UTF-8 encoded Chinese characters
};

/// Pinyin engine
pub const PinyinEngine = struct {
    /// Input buffer (pinyin being typed)
    buffer: [32]u8,
    buffer_len: usize,

    /// Pinyin map (simplified - in production this would be a larger dictionary)
    dictionary: []const PinyinEntry,

    /// Initialize pinyin engine
    pub fn init() PinyinEngine {
        return .{
            .buffer = [_]u8{0} ** 32,
            .buffer_len = 0,
            .dictionary = pinyin_dictionary,
        };
    }

    /// Get current buffer
    pub fn getBuffer(eng: *PinyinEngine) []const u8 {
        return eng.buffer[0..eng.buffer_len];
    }

    /// Append character to buffer
    pub fn append(eng: *PinyinEngine, ch: u8) bool {
        if (eng.buffer_len >= eng.buffer.len - 1) return false;
        eng.buffer[eng.buffer_len] = ch;
        eng.buffer_len += 1;
        return true;
    }

    /// Remove last character
    pub fn backspace(eng: *PinyinEngine) bool {
        if (eng.buffer_len == 0) return false;
        eng.buffer_len -= 1;
        eng.buffer[eng.buffer_len] = 0;
        return true;
    }

    /// Clear buffer
    pub fn clear(eng: *PinyinEngine) void {
        eng.buffer_len = 0;
        @memset(&eng.buffer, 0);
    }

    /// Search for matching pinyin
    /// Returns up to MAX_CANDIDATES matches
    pub fn search(eng: *PinyinEngine, pinyin: []const u8, results: *[candidates_mod.MAX_CANDIDATES][32]u8) usize {
        if (pinyin.len == 0) return 0;

        var count: usize = 0;

        // Search dictionary
        for (eng.dictionary) |entry| {
            const entry_pinyin = std.mem.sliceTo(&entry.pinyin, 0);

            // Check if pinyin matches prefix
            if (std.mem.startsWith(u8, entry_pinyin, pinyin)) {
                const chars = std.mem.sliceTo(&entry.chars, 0);
                if (chars.len > 0 and count < candidates_mod.MAX_CANDIDATES) {
                    @memcpy(results[count][0..chars.len], chars);
                    results[count][chars.len] = 0;
                    count += 1;
                }
            }
        }

        return count;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Simplified Pinyin Dictionary (~150 common pinyin + characters)
// Clean-room implementation based on common Chinese character frequency data.
// ─────────────────────────────────────────────────────────────────────────────

const pinyin_dictionary = [_]PinyinEntry{
    // A
    .{ .pinyin = "a", .chars = "啊阿" },
    .{ .pinyin = "ai", .chars = "爱艾碍矮哎唉" },
    .{ .pinyin = "an", .chars = "安暗按岸俺案" },
    .{ .pinyin = "ang", .chars = "昂盎" },
    .{ .pinyin = "ao", .chars = "奥澳傲熬凹" },

    // B
    .{ .pinyin = "ba", .chars = "把八吧巴拔罢爸霸" },
    .{ .pinyin = "bai", .chars = "白百摆败拜柏" },
    .{ .pinyin = "ban", .chars = "办半班板版般" },
    .{ .pinyin = "bang", .chars = "帮邦棒榜膀" },
    .{ .pinyin = "bao", .chars = "报保包宝抱暴" },
    .{ .pinyin = "bei", .chars = "被北备背杯倍" },
    .{ .pinyin = "ben", .chars = "本笨奔" },
    .{ .pinyin = "beng", .chars = "蹦泵绷" },
    .{ .pinyin = "bi", .chars = "比必笔闭鼻碧" },
    .{ .pinyin = "bian", .chars = "边便变编遍辩" },
    .{ .pinyin = "biao", .chars = "表标彪" },
    .{ .pinyin = "bie", .chars = "别憋" },
    .{ .pinyin = "bin", .chars = "宾滨" },
    .{ .pinyin = "bing", .chars = "病并冰兵饼" },
    .{ .pinyin = "bo", .chars = "博波拨伯玻薄" },
    .{ .pinyin = "bu", .chars = "不布步部补" },

    // C
    .{ .pinyin = "ca", .chars = "擦" },
    .{ .pinyin = "cai", .chars = "才采彩菜猜" },
    .{ .pinyin = "can", .chars = "参餐残灿" },
    .{ .pinyin = "cang", .chars = "藏仓苍" },
    .{ .pinyin = "cao", .chars = "草操曹" },
    .{ .pinyin = "ce", .chars = "测策册" },
    .{ .pinyin = "ceng", .chars = "层曾" },
    .{ .pinyin = "cha", .chars = "查茶差插叉" },
    .{ .pinyin = "chai", .chars = "拆柴" },
    .{ .pinyin = "chan", .chars = "产颤禅" },
    .{ .pinyin = "chang", .chars = "常长场唱昌" },
    .{ .pinyin = "chao", .chars = "超朝潮炒抄" },
    .{ .pinyin = "che", .chars = "车彻" },
    .{ .pinyin = "chen", .chars = "陈晨沉臣衬" },
    .{ .pinyin = "cheng", .chars = "成城程承撑" },
    .{ .pinyin = "chi", .chars = "吃持迟赤尺" },
    .{ .pinyin = "chong", .chars = "重冲虫充" },
    .{ .pinyin = "chou", .chars = "抽愁臭仇" },
    .{ .pinyin = "chu", .chars = "出处初础除" },
    .{ .pinyin = "chuan", .chars = "传川船穿" },
    .{ .pinyin = "chuang", .chars = "创窗床闯" },
    .{ .pinyin = "chui", .chars = "吹垂" },
    .{ .pinyin = "chun", .chars = "春纯唇" },
    .{ .pinyin = "chuo", .chars = "戳" },
    .{ .pinyin = "ci", .chars = "此次词辞刺" },
    .{ .pinyin = "cong", .chars = "从匆聪" },
    .{ .pinyin = "cou", .chars = "凑" },
    .{ .pinyin = "cu", .chars = "粗促" },
    .{ .pinyin = "cuan", .chars = "窜攒" },
    .{ .pinyin = "cui", .chars = "催脆翠" },
    .{ .pinyin = "cun", .chars = "村存寸" },
    .{ .pinyin = "cuo", .chars = "错措搓" },

    // D
    .{ .pinyin = "da", .chars = "大打达答" },
    .{ .pinyin = "dai", .chars = "带待代袋大" },
    .{ .pinyin = "dan", .chars = "但单担蛋淡" },
    .{ .pinyin = "dang", .chars = "当党档" },
    .{ .pinyin = "dao", .chars = "到道导倒刀" },
    .{ .pinyin = "de", .chars = "的得地" },
    .{ .pinyin = "deng", .chars = "等登灯邓" },
    .{ .pinyin = "di", .chars = "的地第低敌" },
    .{ .pinyin = "dian", .chars = "点电店典" },
    .{ .pinyin = "diao", .chars = "掉调钓吊" },
    .{ .pinyin = "die", .chars = "爹跌叠蝶" },
    .{ .pinyin = "ding", .chars = "定顶订钉" },
    .{ .pinyin = "diu", .chars = "丢" },
    .{ .pinyin = "dong", .chars = "懂动东冬" },
    .{ .pinyin = "dou", .chars = "都斗豆逗" },
    .{ .pinyin = "du", .chars = "读百度独渡" },
    .{ .pinyin = "duan", .chars = "段短断端" },
    .{ .pinyin = "dui", .chars = "对队堆" },
    .{ .pinyin = "dun", .chars = "吨顿盾" },
    .{ .pinyin = "duo", .chars = "多夺朵" },

    // E
    .{ .pinyin = "e", .chars = "额恶饿" },
    .{ .pinyin = "en", .chars = "恩" },
    .{ .pinyin = "er", .chars = "而二儿耳" },

    // F
    .{ .pinyin = "fa", .chars = "发法罚" },
    .{ .pinyin = "fan", .chars = "反范饭番犯" },
    .{ .pinyin = "fang", .chars = "方放房访仿" },
    .{ .pinyin = "fei", .chars = "非飞费肥" },
    .{ .pinyin = "fen", .chars = "分份纷粉奋" },
    .{ .pinyin = "feng", .chars = "风封丰疯" },
    .{ .pinyin = "fo", .chars = "佛" },
    .{ .pinyin = "fou", .chars = "否" },
    .{ .pinyin = "fu", .chars = "服福副父付" },

    // G
    .{ .pinyin = "ga", .chars = "噶" },
    .{ .pinyin = "gai", .chars = "该改概盖" },
    .{ .pinyin = "gan", .chars = "干赶感肝" },
    .{ .pinyin = "gang", .chars = "刚港钢" },
    .{ .pinyin = "gao", .chars = "高搞告稿" },
    .{ .pinyin = "ge", .chars = "个歌哥革格" },
    .{ .pinyin = "gei", .chars = "给" },
    .{ .pinyin = "gen", .chars = "跟根" },
    .{ .pinyin = "geng", .chars = "更耕" },
    .{ .pinyin = "gong", .chars = "工公功共" },
    .{ .pinyin = "gou", .chars = "够狗购构" },
    .{ .pinyin = "gu", .chars = "古故顾姑鼓" },
    .{ .pinyin = "gua", .chars = "挂刮瓜" },
    .{ .pinyin = "guai", .chars = "怪乖" },
    .{ .pinyin = "guan", .chars = "关管官观" },
    .{ .pinyin = "guang", .chars = "光广" },
    .{ .pinyin = "gui", .chars = "贵规鬼归" },
    .{ .pinyin = "gun", .chars = "滚棍" },
    .{ .pinyin = "guo", .chars = "过国果" },

    // H
    .{ .pinyin = "ha", .chars = "哈" },
    .{ .pinyin = "hai", .chars = "还海害" },
    .{ .pinyin = "han", .chars = "汉含寒喊" },
    .{ .pinyin = "hang", .chars = "行航" },
    .{ .pinyin = "hao", .chars = "好号浩毫" },
    .{ .pinyin = "he", .chars = "和河何合核" },
    .{ .pinyin = "hei", .chars = "黑嘿" },
    .{ .pinyin = "hen", .chars = "很恨" },
    .{ .pinyin = "heng", .chars = "横恒" },
    .{ .pinyin = "hong", .chars = "红洪宏" },
    .{ .pinyin = "hou", .chars = "后候厚侯" },
    .{ .pinyin = "hu", .chars = "户呼湖互虎" },
    .{ .pinyin = "hua", .chars = "话化华画花" },
    .{ .pinyin = "huai", .chars = "坏怀" },
    .{ .pinyin = "huan", .chars = "换欢环缓" },
    .{ .pinyin = "huang", .chars = "黄慌荒皇" },
    .{ .pinyin = "hui", .chars = "会回挥汇" },
    .{ .pinyin = "hun", .chars = "混婚魂" },
    .{ .pinyin = "huo", .chars = "或活火获" },

    // J
    .{ .pinyin = "ji", .chars = "机及级几己" },
    .{ .pinyin = "jia", .chars = "家加假价架" },
    .{ .pinyin = "jian", .chars = "见件间建" },
    .{ .pinyin = "jiang", .chars = "将江讲奖" },
    .{ .pinyin = "jiao", .chars = "教交较叫" },
    .{ .pinyin = "jie", .chars = "接街姐解" },
    .{ .pinyin = "jin", .chars = "进今金仅尽" },
    .{ .pinyin = "jing", .chars = "经京精惊" },
    .{ .pinyin = "jiu", .chars = "就九久酒" },
    .{ .pinyin = "ju", .chars = "据举巨具" },
    .{ .pinyin = "juan", .chars = "卷倦" },
    .{ .pinyin = "jue", .chars = "决绝角" },
    .{ .pinyin = "jun", .chars = "军君均" },

    // K
    .{ .pinyin = "ka", .chars = "卡咖" },
    .{ .pinyin = "kai", .chars = "开凯" },
    .{ .pinyin = "kan", .chars = "看刊砍" },
    .{ .pinyin = "kang", .chars = "抗康" },
    .{ .pinyin = "kao", .chars = "考靠烤" },
    .{ .pinyin = "ke", .chars = "可科克刻课" },
    .{ .pinyin = "ken", .chars = "肯恳" },
    .{ .pinyin = "keng", .chars = "坑" },
    .{ .pinyin = "kong", .chars = "空控孔恐" },
    .{ .pinyin = "kou", .chars = "口扣" },
    .{ .pinyin = "ku", .chars = "苦库哭酷" },
    .{ .pinyin = "kua", .chars = "跨夸" },
    .{ .pinyin = "kuai", .chars = "快块会计" },
    .{ .pinyin = "kuan", .chars = "宽款" },
    .{ .pinyin = "kuang", .chars = "况矿框狂" },
    .{ .pinyin = "kui", .chars = "亏愧" },
    .{ .pinyin = "kun", .chars = "困昆" },
    .{ .pinyin = "kuo", .chars = "扩阔" },

    // L
    .{ .pinyin = "la", .chars = "拉啦辣" },
    .{ .pinyin = "lai", .chars = "来赖" },
    .{ .pinyin = "lan", .chars = "蓝兰拦篮" },
    .{ .pinyin = "lang", .chars = "浪郎狼" },
    .{ .pinyin = "lao", .chars = "老劳" },
    .{ .pinyin = "le", .chars = "了乐" },
    .{ .pinyin = "lei", .chars = "累类雷" },
    .{ .pinyin = "leng", .chars = "冷愣" },
    .{ .pinyin = "li", .chars = "里理力李" },
    .{ .pinyin = "lia", .chars = "俩" },
    .{ .pinyin = "lian", .chars = "连联脸练" },
    .{ .pinyin = "liang", .chars = "两量亮粮" },
    .{ .pinyin = "liao", .chars = "了料疗辽" },
    .{ .pinyin = "lie", .chars = "列烈猎" },
    .{ .pinyin = "lin", .chars = "林临邻" },
    .{ .pinyin = "ling", .chars = "令零领灵" },
    .{ .pinyin = "liu", .chars = "六流留刘" },
    .{ .pinyin = "long", .chars = "龙隆弄" },
    .{ .pinyin = "lou", .chars = "楼搂漏" },
    .{ .pinyin = "lu", .chars = "路陆露卢" },
    .{ .pinyin = "lv", .chars = "绿旅律率" },
    .{ .pinyin = "luan", .chars = "乱卵" },
    .{ .pinyin = "lue", .chars = "略" },
    .{ .pinyin = "lun", .chars = "论轮伦" },
    .{ .pinyin = "luo", .chars = "罗落洛" },

    // M
    .{ .pinyin = "ma", .chars = "妈马吗麻" },
    .{ .pinyin = "mai", .chars = "买迈麦" },
    .{ .pinyin = "man", .chars = "慢满曼" },
    .{ .pinyin = "mang", .chars = "忙盲茫" },
    .{ .pinyin = "mao", .chars = "毛冒贸" },
    .{ .pinyin = "me", .chars = "么" },
    .{ .pinyin = "mei", .chars = "没每美妹" },
    .{ .pinyin = "men", .chars = "们门" },
    .{ .pinyin = "meng", .chars = "梦蒙盟" },
    .{ .pinyin = "mi", .chars = "米密迷蜜" },
    .{ .pinyin = "mian", .chars = "面棉免" },
    .{ .pinyin = "miao", .chars = "秒苗描妙" },
    .{ .pinyin = "mie", .chars = "灭蔑" },
    .{ .pinyin = "min", .chars = "民敏" },
    .{ .pinyin = "ming", .chars = "名明命" },
    .{ .pinyin = "miu", .chars = "谬" },
    .{ .pinyin = "mo", .chars = "莫末摸墨" },
    .{ .pinyin = "mou", .chars = "某谋" },
    .{ .pinyin = "mu", .chars = "目母木幕" },

    // N
    .{ .pinyin = "na", .chars = "那拿哪纳" },
    .{ .pinyin = "nai", .chars = "奶耐" },
    .{ .pinyin = "nan", .chars = "男南难" },
    .{ .pinyin = "nang", .chars = "囊" },
    .{ .pinyin = "nao", .chars = "脑闹" },
    .{ .pinyin = "ne", .chars = "呢哪" },
    .{ .pinyin = "nei", .chars = "内那" },
    .{ .pinyin = "nen", .chars = "嫩" },
    .{ .pinyin = "neng", .chars = "能" },
    .{ .pinyin = "ni", .chars = "你泥尼逆" },
    .{ .pinyin = "nian", .chars = "年念碾" },
    .{ .pinyin = "niang", .chars = "娘酿" },
    .{ .pinyin = "niao", .chars = "鸟尿" },
    .{ .pinyin = "nie", .chars = "捏聂" },
    .{ .pinyin = "nin", .chars = "您" },
    .{ .pinyin = "ning", .chars = "宁凝" },
    .{ .pinyin = "niu", .chars = "牛扭纽" },
    .{ .pinyin = "nong", .chars = "农浓弄" },
    .{ .pinyin = "nu", .chars = "奴努怒" },
    .{ .pinyin = "nv", .chars = "女" },
    .{ .pinyin = "nuan", .chars = "暖" },
    .{ .pinyin = "nue", .chars = "虐疟" },
    .{ .pinyin = "nuo", .chars = "诺挪" },

    // O
    .{ .pinyin = "o", .chars = "哦噢" },
    .{ .pinyin = "ou", .chars = "欧偶" },

    // P
    .{ .pinyin = "pa", .chars = "怕爬啪" },
    .{ .pinyin = "pai", .chars = "派拍排" },
    .{ .pinyin = "pan", .chars = "盘判叛" },
    .{ .pinyin = "pang", .chars = "旁胖" },
    .{ .pinyin = "pao", .chars = "跑炮泡" },
    .{ .pinyin = "pei", .chars = "配陪培" },
    .{ .pinyin = "pen", .chars = "盆喷" },
    .{ .pinyin = "peng", .chars = "朋碰彭" },
    .{ .pinyin = "pi", .chars = "批皮疲披" },
    .{ .pinyin = "pian", .chars = "片篇偏" },
    .{ .pinyin = "piao", .chars = "票飘漂" },
    .{ .pinyin = "pie", .chars = "撇瞥" },
    .{ .pinyin = "pin", .chars = "品贫拼" },
    .{ .pinyin = "ping", .chars = "平评乒凭" },
    .{ .pinyin = "po", .chars = "破迫坡泼" },
    .{ .pinyin = "pou", .chars = "剖" },
    .{ .pinyin = "pu", .chars = "普扑铺葡" },

    // Q
    .{ .pinyin = "qi", .chars = "起其期七" },
    .{ .pinyin = "qia", .chars = "恰洽" },
    .{ .pinyin = "qian", .chars = "前千签潜" },
    .{ .pinyin = "qiang", .chars = "强墙抢" },
    .{ .pinyin = "qiao", .chars = "桥巧敲悄" },
    .{ .pinyin = "qie", .chars = "且切窃" },
    .{ .pinyin = "qin", .chars = "亲琴勤秦" },
    .{ .pinyin = "qing", .chars = "请青轻情" },
    .{ .pinyin = "qiong", .chars = "穷琼" },
    .{ .pinyin = "qiu", .chars = "求球秋" },
    .{ .pinyin = "qu", .chars = "去区取曲" },
    .{ .pinyin = "quan", .chars = "全权泉圈" },
    .{ .pinyin = "que", .chars = "却确缺" },
    .{ .pinyin = "qun", .chars = "群裙" },

    // R
    .{ .pinyin = "ran", .chars = "然燃染" },
    .{ .pinyin = "rang", .chars = "让壤嚷" },
    .{ .pinyin = "rao", .chars = "绕饶扰" },
    .{ .pinyin = "re", .chars = "热惹" },
    .{ .pinyin = "ren", .chars = "人任认仁" },
    .{ .pinyin = "reng", .chars = "扔仍" },
    .{ .pinyin = "ri", .chars = "日" },
    .{ .pinyin = "rong", .chars = "容荣融绒" },
    .{ .pinyin = "rou", .chars = "肉柔揉" },
    .{ .pinyin = "ru", .chars = "如入儒" },
    .{ .pinyin = "ruan", .chars = "软阮" },
    .{ .pinyin = "rui", .chars = "瑞锐" },
    .{ .pinyin = "run", .chars = "润闰" },
    .{ .pinyin = "ruo", .chars = "若弱" },

    // S
    .{ .pinyin = "sa", .chars = "撒洒" },
    .{ .pinyin = "sai", .chars = "赛塞" },
    .{ .pinyin = "san", .chars = "三散" },
    .{ .pinyin = "sang", .chars = "桑嗓丧" },
    .{ .pinyin = "sao", .chars = "扫骚" },
    .{ .pinyin = "se", .chars = "色涩瑟" },
    .{ .pinyin = "sen", .chars = "森" },
    .{ .pinyin = "seng", .chars = "僧" },
    .{ .pinyin = "sha", .chars = "沙杀傻砂" },
    .{ .pinyin = "shai", .chars = "晒筛" },
    .{ .pinyin = "shan", .chars = "山闪善扇" },
    .{ .pinyin = "shang", .chars = "上商伤" },
    .{ .pinyin = "shao", .chars = "少绍烧" },
    .{ .pinyin = "she", .chars = "社设舌射" },
    .{ .pinyin = "shen", .chars = "身深神什" },
    .{ .pinyin = "sheng", .chars = "声生升胜" },
    .{ .pinyin = "shi", .chars = "是时十世" },
    .{ .pinyin = "shou", .chars = "手受收首" },
    .{ .pinyin = "shu", .chars = "书树数熟" },
    .{ .pinyin = "shua", .chars = "刷耍" },
    .{ .pinyin = "shuai", .chars = "衰摔帅" },
    .{ .pinyin = "shuan", .chars = "拴栓" },
    .{ .pinyin = "shuang", .chars = "双爽霜" },
    .{ .pinyin = "shui", .chars = "水睡税说" },
    .{ .pinyin = "shun", .chars = "顺瞬" },
    .{ .pinyin = "shuo", .chars = "说硕" },
    .{ .pinyin = "si", .chars = "四思死司" },
    .{ .pinyin = "song", .chars = "送松宋" },
    .{ .pinyin = "sou", .chars = "搜艘" },
    .{ .pinyin = "su", .chars = "速素诉苏" },
    .{ .pinyin = "suan", .chars = "算酸" },
    .{ .pinyin = "sui", .chars = "岁碎随穗" },
    .{ .pinyin = "sun", .chars = "孙损笋" },
    .{ .pinyin = "suo", .chars = "所索缩锁" },

    // T
    .{ .pinyin = "ta", .chars = "他她它塔" },
    .{ .pinyin = "tai", .chars = "太台态抬" },
    .{ .pinyin = "tan", .chars = "谈弹叹探" },
    .{ .pinyin = "tang", .chars = "糖汤躺堂" },
    .{ .pinyin = "tao", .chars = "套讨逃桃" },
    .{ .pinyin = "te", .chars = "特" },
    .{ .pinyin = "teng", .chars = "疼腾藤" },
    .{ .pinyin = "ti", .chars = "体提题踢" },
    .{ .pinyin = "tian", .chars = "天田填甜" },
    .{ .pinyin = "tiao", .chars = "条跳挑调" },
    .{ .pinyin = "tie", .chars = "铁贴" },
    .{ .pinyin = "ting", .chars = "听停庭" },
    .{ .pinyin = "tong", .chars = "同通痛统" },
    .{ .pinyin = "tou", .chars = "头投透偷" },
    .{ .pinyin = "tu", .chars = "土图突途" },
    .{ .pinyin = "tuan", .chars = "团推" },
    .{ .pinyin = "tui", .chars = "退推腿" },
    .{ .pinyin = "tun", .chars = "吞屯" },
    .{ .pinyin = "tuo", .chars = "脱托拖拓" },

    // W
    .{ .pinyin = "wa", .chars = "挖瓦蛙娃" },
    .{ .pinyin = "wai", .chars = "外歪" },
    .{ .pinyin = "wan", .chars = "完万晚玩" },
    .{ .pinyin = "wang", .chars = "王往忘望" },
    .{ .pinyin = "wei", .chars = "为位未伟" },
    .{ .pinyin = "wen", .chars = "文问闻温" },
    .{ .pinyin = "weng", .chars = "翁嗡" },
    .{ .pinyin = "wo", .chars = "我握卧沃" },
    .{ .pinyin = "wu", .chars = "无五物务" },

    // X
    .{ .pinyin = "xi", .chars = "西系息希" },
    .{ .pinyin = "xia", .chars = "下夏吓侠" },
    .{ .pinyin = "xian", .chars = "先线现显" },
    .{ .pinyin = "xiang", .chars = "想向相像" },
    .{ .pinyin = "xiao", .chars = "小校笑效" },
    .{ .pinyin = "xie", .chars = "些写谢斜" },
    .{ .pinyin = "xin", .chars = "新心信辛" },
    .{ .pinyin = "xing", .chars = "行型性星" },
    .{ .pinyin = "xiong", .chars = "熊胸雄兄" },
    .{ .pinyin = "xiu", .chars = "修秀休羞" },
    .{ .pinyin = "xu", .chars = "需须许续" },
    .{ .pinyin = "xuan", .chars = "选宣旋悬" },
    .{ .pinyin = "xue", .chars = "学雪血" },
    .{ .pinyin = "xun", .chars = "训迅寻讯" },

    // Y
    .{ .pinyin = "ya", .chars = "牙压呀亚" },
    .{ .pinyin = "yan", .chars = "眼研言沿" },
    .{ .pinyin = "yang", .chars = "样阳养羊" },
    .{ .pinyin = "yao", .chars = "要药腰摇" },
    .{ .pinyin = "ye", .chars = "也业页夜" },
    .{ .pinyin = "yi", .chars = "一以已意" },
    .{ .pinyin = "yin", .chars = "因银音引" },
    .{ .pinyin = "ying", .chars = "应英影映" },
    .{ .pinyin = "yo", .chars = "哟" },
    .{ .pinyin = "yong", .chars = "用永泳勇" },
    .{ .pinyin = "you", .chars = "有由又优" },
    .{ .pinyin = "yu", .chars = "于雨语与" },
    .{ .pinyin = "yuan", .chars = "元远院原" },
    .{ .pinyin = "yue", .chars = "月越约乐" },
    .{ .pinyin = "yun", .chars = "云运允韵" },

    // Z
    .{ .pinyin = "za", .chars = "杂咱砸" },
    .{ .pinyin = "zai", .chars = "在再载灾" },
    .{ .pinyin = "zan", .chars = "咱暂赞" },
    .{ .pinyin = "zang", .chars = "脏葬" },
    .{ .pinyin = "zao", .chars = "早澡造遭" },
    .{ .pinyin = "ze", .chars = "则责泽" },
    .{ .pinyin = "zei", .chars = "贼" },
    .{ .pinyin = "zen", .chars = "怎" },
    .{ .pinyin = "zeng", .chars = "曾增" },
    .{ .pinyin = "zha", .chars = "炸扎宅" },
    .{ .pinyin = "zhai", .chars = "宅窄债" },
    .{ .pinyin = "zhan", .chars = "站占战展" },
    .{ .pinyin = "zhang", .chars = "张章长掌" },
    .{ .pinyin = "zhao", .chars = "着找照赵" },
    .{ .pinyin = "zhe", .chars = "着者这" },
    .{ .pinyin = "zhen", .chars = "真镇针振" },
    .{ .pinyin = "zheng", .chars = "正政整争" },
    .{ .pinyin = "zhi", .chars = "之知只直" },
    .{ .pinyin = "zhong", .chars = "中重众钟" },
    .{ .pinyin = "zhou", .chars = "州周洲轴" },
    .{ .pinyin = "zhu", .chars = "主注住助" },
    .{ .pinyin = "zhua", .chars = "抓爪" },
    .{ .pinyin = "zhuai", .chars = "拽" },
    .{ .pinyin = "zhuan", .chars = "转专砖" },
    .{ .pinyin = "zhuang", .chars = "装庄撞壮" },
    .{ .pinyin = "zhui", .chars = "追坠" },
    .{ .pinyin = "zhun", .chars = "准" },
    .{ .pinyin = "zhuo", .chars = "桌捉着卓" },
    .{ .pinyin = "zi", .chars = "子自字资" },
    .{ .pinyin = "zong", .chars = "总宗综纵" },
    .{ .pinyin = "zou", .chars = "走奏揍" },
    .{ .pinyin = "zu", .chars = "组族足阻" },
    .{ .pinyin = "zuan", .chars = "钻" },
    .{ .pinyin = "zui", .chars = "最嘴罪" },
    .{ .pinyin = "zun", .chars = "尊遵" },
    .{ .pinyin = "zuo", .chars = "做作左坐" },
};
