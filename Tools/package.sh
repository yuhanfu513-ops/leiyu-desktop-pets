#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh
"build/雷军桌宠.app/Contents/MacOS/LeiYuPet" --self-test
"build/余承东桌宠.app/Contents/MacOS/LeiYuPet" --self-test

release="Work/Release/雷余双桌宠"
rm -rf "$release"
mkdir -p "$release"
cp -R "build/雷军桌宠.app" "build/余承东桌宠.app" "$release/"

cat > "$release/使用说明.txt" <<'TXT'
雷余双桌宠 2.0

1. 将雷军桌宠.app 和 余承东桌宠.app 都拖入“应用程序”，分别双击打开。
2. 没靠近时点击任一头像：随机说一段自己的台词，头顶显示字幕，并上下弹动；另一位不会弹动，也不会出声。
3. 两位靠近时点击任一头像：雷军先说一段，余承东后说对应的一段；只有正在说话的一方弹动、显示字幕。
4. 一段没说完时点另一位：没靠近时切换声音；靠近时重新开始一组问答，仍然雷军先说。
5. 把两个头像拖近：两颗头会向对方倾斜，不会自动播放声音；拉开后慢慢回正。
6. 右键任一头像：随机说一段、两人对话一句、挑一段（带字幕）、停止播放、音量、歪头距离、人物大小、打开另一位、退出。
7. 台词共 17 段：雷军 9 段、余承东 8 段，配成 8 组问答；合并段的字幕会跟着声音一句一句切换，播完约 0.4 秒后消失。
8. 更新版本时请先退出两位桌宠，再替换 app；如果运行中替换，旧进程可能提示无法播放或音画不一致，退出重开即可。
9. 首次打开如果提示“无法验证开发者”，右键点击 app → 打开，或在终端执行：
   xattr -dr com.apple.quarantine /Applications/雷军桌宠.app /Applications/余承东桌宠.app

支持 Apple Silicon Mac、macOS 14 或更新系统。
TXT

rm -f "雷余双桌宠-安装包.zip"
ditto -c -k --sequesterRsrc --keepParent "$release" "雷余双桌宠-安装包.zip"
printf '已打包：%s\n' "雷余双桌宠-安装包.zip"
