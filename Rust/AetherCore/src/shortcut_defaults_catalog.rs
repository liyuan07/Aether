// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
// Catalog extracted from the native b75acda defaults; parity is checked against a frozen Swift reference.
use super::{Action, Recipe};
use crate::shortcuts::Key;
pub(super) const RECIPES: &[Recipe] = &[
    Recipe {
        name: "打开 Chrome",
        source: Key {
            code: 14,
            physical: 0,
            modifiers: 2,
        },
        action: Action::Application(
            "Google Chrome",
            "com.google.Chrome",
            "/Applications/Google Chrome.app",
        ),
    },
    Recipe {
        name: "打开 Finder 桌面",
        source: Key {
            code: 18,
            physical: 0,
            modifiers: 2,
        },
        action: Action::Folder(0),
    },
    Recipe {
        name: "在当前路径打开终端",
        source: Key {
            code: 17,
            physical: 0,
            modifiers: 2,
        },
        action: Action::Terminal,
    },
    Recipe {
        name: "打开 Codex",
        source: Key {
            code: 8,
            physical: 0,
            modifiers: 2,
        },
        action: Action::Application("Codex", "com.openai.codex", "/Applications/ChatGPT.app"),
    },
    Recipe {
        name: "打开 Mail",
        source: Key {
            code: 46,
            physical: 0,
            modifiers: 2,
        },
        action: Action::Application("Mail", "com.apple.mail", "/System/Applications/Mail.app"),
    },
    Recipe {
        name: "打开微信",
        source: Key {
            code: 13,
            physical: 0,
            modifiers: 2,
        },
        action: Action::Application("微信", "com.tencent.xinWeChat", "/Applications/WeChat.app"),
    },
    Recipe {
        name: "打开桌面 code 文件夹",
        source: Key {
            code: 19,
            physical: 0,
            modifiers: 2,
        },
        action: Action::Folder(1),
    },
    Recipe {
        name: "显示桌面",
        source: Key {
            code: 2,
            physical: 0,
            modifiers: 2,
        },
        action: Action::Desktop,
    },
    Recipe {
        name: "Vim 向左",
        source: Key {
            code: 4,
            physical: 0,
            modifiers: 10,
        },
        action: Action::Remap(Key {
            code: 123,
            physical: 0,
            modifiers: 0,
        }),
    },
    Recipe {
        name: "Vim 向下",
        source: Key {
            code: 38,
            physical: 0,
            modifiers: 10,
        },
        action: Action::Remap(Key {
            code: 125,
            physical: 0,
            modifiers: 0,
        }),
    },
    Recipe {
        name: "Vim 向上",
        source: Key {
            code: 40,
            physical: 0,
            modifiers: 10,
        },
        action: Action::Remap(Key {
            code: 126,
            physical: 0,
            modifiers: 0,
        }),
    },
    Recipe {
        name: "Vim 向右",
        source: Key {
            code: 37,
            physical: 0,
            modifiers: 10,
        },
        action: Action::Remap(Key {
            code: 124,
            physical: 0,
            modifiers: 0,
        }),
    },
    Recipe {
        name: "Vim 向左",
        source: Key {
            code: 4,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 123,
            physical: 0,
            modifiers: 0,
        }),
    },
    Recipe {
        name: "Vim 向下",
        source: Key {
            code: 38,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 125,
            physical: 0,
            modifiers: 0,
        }),
    },
    Recipe {
        name: "Vim 向上",
        source: Key {
            code: 40,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 126,
            physical: 0,
            modifiers: 0,
        }),
    },
    Recipe {
        name: "Vim 向右",
        source: Key {
            code: 37,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 124,
            physical: 0,
            modifiers: 0,
        }),
    },
    Recipe {
        name: "向左跳一个单词",
        source: Key {
            code: 16,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 123,
            physical: 0,
            modifiers: 2,
        }),
    },
    Recipe {
        name: "到当前段落结尾",
        source: Key {
            code: 32,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 125,
            physical: 0,
            modifiers: 2,
        }),
    },
    Recipe {
        name: "到当前段落开头",
        source: Key {
            code: 34,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 126,
            physical: 0,
            modifiers: 2,
        }),
    },
    Recipe {
        name: "向右跳一个单词",
        source: Key {
            code: 31,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 124,
            physical: 0,
            modifiers: 2,
        }),
    },
    Recipe {
        name: "到当前行开头",
        source: Key {
            code: 45,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 123,
            physical: 0,
            modifiers: 8,
        }),
    },
    Recipe {
        name: "到文档最后面",
        source: Key {
            code: 46,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 125,
            physical: 0,
            modifiers: 8,
        }),
    },
    Recipe {
        name: "到文档最前面",
        source: Key {
            code: 43,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 126,
            physical: 0,
            modifiers: 8,
        }),
    },
    Recipe {
        name: "到当前行结尾",
        source: Key {
            code: 47,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 124,
            physical: 0,
            modifiers: 8,
        }),
    },
    Recipe {
        name: "到当前行开头",
        source: Key {
            code: 32,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 123,
            physical: 0,
            modifiers: 8,
        }),
    },
    Recipe {
        name: "到当前行结尾",
        source: Key {
            code: 34,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 124,
            physical: 0,
            modifiers: 8,
        }),
    },
    Recipe {
        name: "到当前段落开头",
        source: Key {
            code: 45,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 126,
            physical: 0,
            modifiers: 2,
        }),
    },
    Recipe {
        name: "到文档最前面",
        source: Key {
            code: 46,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 126,
            physical: 0,
            modifiers: 8,
        }),
    },
    Recipe {
        name: "到文档最后面",
        source: Key {
            code: 43,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 125,
            physical: 0,
            modifiers: 8,
        }),
    },
    Recipe {
        name: "到当前段落结尾",
        source: Key {
            code: 47,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 125,
            physical: 0,
            modifiers: 2,
        }),
    },
    Recipe {
        name: "到当前行结尾",
        source: Key {
            code: 32,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 124,
            physical: 0,
            modifiers: 8,
        }),
    },
    Recipe {
        name: "到当前行开头",
        source: Key {
            code: 34,
            physical: 320,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 123,
            physical: 0,
            modifiers: 8,
        }),
    },
    Recipe {
        name: "Vim 向左",
        source: Key {
            code: 4,
            physical: 256,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 123,
            physical: 0,
            modifiers: 0,
        }),
    },
    Recipe {
        name: "Vim 向下",
        source: Key {
            code: 38,
            physical: 256,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 125,
            physical: 0,
            modifiers: 0,
        }),
    },
    Recipe {
        name: "Vim 向上",
        source: Key {
            code: 40,
            physical: 256,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 126,
            physical: 0,
            modifiers: 0,
        }),
    },
    Recipe {
        name: "Vim 向右",
        source: Key {
            code: 37,
            physical: 256,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 124,
            physical: 0,
            modifiers: 0,
        }),
    },
    Recipe {
        name: "向左跳一个单词",
        source: Key {
            code: 16,
            physical: 256,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 123,
            physical: 0,
            modifiers: 2,
        }),
    },
    Recipe {
        name: "到当前行结尾",
        source: Key {
            code: 32,
            physical: 256,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 124,
            physical: 0,
            modifiers: 8,
        }),
    },
    Recipe {
        name: "到当前行开头",
        source: Key {
            code: 34,
            physical: 256,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 123,
            physical: 0,
            modifiers: 8,
        }),
    },
    Recipe {
        name: "向右跳一个单词",
        source: Key {
            code: 31,
            physical: 256,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 124,
            physical: 0,
            modifiers: 2,
        }),
    },
    Recipe {
        name: "到当前段落开头",
        source: Key {
            code: 45,
            physical: 256,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 126,
            physical: 0,
            modifiers: 2,
        }),
    },
    Recipe {
        name: "到文档最后面",
        source: Key {
            code: 46,
            physical: 256,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 125,
            physical: 0,
            modifiers: 8,
        }),
    },
    Recipe {
        name: "到文档最前面",
        source: Key {
            code: 43,
            physical: 256,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 126,
            physical: 0,
            modifiers: 8,
        }),
    },
    Recipe {
        name: "到当前段落结尾",
        source: Key {
            code: 47,
            physical: 256,
            modifiers: 8,
        },
        action: Action::Remap(Key {
            code: 125,
            physical: 0,
            modifiers: 2,
        }),
    },
    Recipe {
        name: "打开 Finder 桌面",
        source: Key {
            code: 18,
            physical: 256,
            modifiers: 2,
        },
        action: Action::Folder(0),
    },
    Recipe {
        name: "打开桌面 code 文件夹",
        source: Key {
            code: 19,
            physical: 256,
            modifiers: 2,
        },
        action: Action::Folder(1),
    },
    Recipe {
        name: "在当前路径打开终端",
        source: Key {
            code: 17,
            physical: 256,
            modifiers: 2,
        },
        action: Action::Terminal,
    },
    Recipe {
        name: "显示桌面",
        source: Key {
            code: 2,
            physical: 256,
            modifiers: 2,
        },
        action: Action::Desktop,
    },
    Recipe {
        name: "窗口左半屏",
        source: Key {
            code: 123,
            physical: 256,
            modifiers: 2,
        },
        action: Action::Layout(0),
    },
    Recipe {
        name: "窗口右半屏",
        source: Key {
            code: 124,
            physical: 256,
            modifiers: 2,
        },
        action: Action::Layout(1),
    },
    Recipe {
        name: "窗口下半屏",
        source: Key {
            code: 125,
            physical: 256,
            modifiers: 2,
        },
        action: Action::Layout(2),
    },
    Recipe {
        name: "窗口上半屏",
        source: Key {
            code: 126,
            physical: 256,
            modifiers: 2,
        },
        action: Action::Layout(3),
    },
    Recipe {
        name: "系统显示桌面",
        source: Key {
            code: 2,
            physical: 0,
            modifiers: 12,
        },
        action: Action::Desktop,
    },
];
pub(super) const GROUPS: &[&[usize]] = &[
    &[0, 1, 2],
    &[3, 4, 5, 6, 7],
    &[8, 9, 10, 11],
    &[12, 13, 14, 15],
    &[16, 17, 18, 19, 20, 21, 22, 23],
    &[16, 24, 25, 19, 26, 27, 28, 29],
    &[16, 30, 31, 19, 26, 21, 22, 29],
    &[32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43],
    &[44, 45, 46, 47, 48, 49, 50, 51],
    &[44, 45, 46, 48, 49, 50, 51],
    &[44, 45, 46, 48, 49, 50, 51, 52],
    &[47],
    &[52],
];
