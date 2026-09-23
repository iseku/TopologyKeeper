#!/usr/bin/env bash
# 测量 coreaudiod（或任意进程）的 CPU 占用 —— 用中位数代替"看一眼"。
#
# ## 为什么需要它
#
# 音频配置（采样率 / 缓冲帧数 / 延迟目标）之间的 CPU 差异往往是
# **0.5 个百分点**量级。必须先知道**本方法的噪声下限**，才能判断某个差异是否真实：
# 用户实测的经验值是波动 **±0.1%**（反复测多次、每次观察 1 分钟以上）——
# 于是 0.5% 的差异就是**真实效应**（5 倍于噪声），而若是 ±1% 的波动则不足以区分。
#
# ## 正确用法（配对测量）
#
# 1. 固定播放条件：同一个播放源、同一音量，关掉其它出声的 App；
# 2. 当前配置测一次；
# 3. 只改**一个**变量（例如缓冲 512 → 256），**不要关播放源**，再测一次；
# 4. 来回各测 2~3 轮（A/B/A/B），比较各自的中位数；
# 5. 中位数差异明显大于输出的"波动范围"才算真有差异。
#
# 用法：
#   Scripts/measure_coreaudio_cpu.sh [采样秒数] [进程名] [预热秒数]
#   Scripts/measure_coreaudio_cpu.sh 30                       # coreaudiod，30 秒 + 5 秒预热
#   Scripts/measure_coreaudio_cpu.sh 15 TopologyKeeper
#
# ## 为什么默认有"预热期"
#
# 改设备缓冲（或任何会重启音频流的操作）之后，coreaudiod 有一段**过渡态**：
# 实测把它从 512 改成 256 帧后，采样序列里出现过 **11.5% 的单点尖峰**，
# 而稳定段只有 0.6% —— 若把过渡态算进中位数，比较结果就不可信了。
# 因此脚本先预热若干秒（读数照常显示，但**不计入样本**）。
set -euo pipefail

# 本脚本按 **bash** 编写（Shebang 指向 bash）。若被 zsh 等其它 shell 显式执行，
# 数组/内建命令的行为会不一样、报错也难懂 —— 所以这里先挡住，给出明确用法。
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "❌ 本脚本需要 bash 解释（当前不是 bash）。" >&2
    echo "   请用：bash Scripts/measure_coreaudio_cpu.sh [秒数] [进程名]" >&2
    echo "   或直接执行 ./Scripts/measure_coreaudio_cpu.sh（让 Shebang 生效）。" >&2
    exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

SECONDS_TO_SAMPLE="${1:-30}"
PROCESS_NAME="${2:-coreaudiod}"
WARMUP_SECONDS="${3:-5}"

PID="$(pgrep -x "${PROCESS_NAME}" | head -1 || true)"
if [[ -z "${PID}" ]]; then
    echo "❌ 找不到进程 ${PROCESS_NAME}（核心音频服务通常名为 coreaudiod）" >&2
    exit 1
fi

# ── 预热：丢弃配置切换的过渡态（见文件头的说明）──────────────────
if ((WARMUP_SECONDS > 0)); then
    echo "预热 ${WARMUP_SECONDS} 秒（等配置切换的余波过去，这些读数不计入样本）…"
    for ((i = 1; i <= WARMUP_SECONDS; i++)); do
        value="$(ps -o %cpu= -p "${PID}" | tr -d ' ')"
        printf '\r  预热 %d/%d（当前 %s%%）' "${i}" "${WARMUP_SECONDS}" "${value}"
        sleep 1
    done
    printf '\n'
fi

echo "采样 ${PROCESS_NAME} (pid ${PID}) 共 ${SECONDS_TO_SAMPLE} 秒，每秒一次…"
samples=()
for ((i = 1; i <= SECONDS_TO_SAMPLE; i++)); do
    # %cpu= 只输出数字（不带列头与进程名，避免解析脆弱）
    value="$(ps -o %cpu= -p "${PID}" | tr -d ' ')"
    samples+=("${value}")
    printf '\r  已采样 %d/%d（当前 %s%%）' "${i}" "${SECONDS_TO_SAMPLE}" "${value}"
    sleep 1
done
printf '\n'

# 排序后取中位数；**差值必须用浮点算** —— %cpu 是小数，shell 的 $(( )) 只做整数运算。
#
# ⚠️ 这里**不能用 `mapfile`/`readarray`**：它们是 bash 4.0+ 的内建命令，
#    而 macOS 自带的是 bash 3.2（本机实测 `/bin/bash --version` = 3.2.57）。
#    用 while-read 循环读入是 bash 3.2 兼容写法（项目 `build.sh` 里也记过同类限制）。
sorted=()
while IFS= read -r line; do
    sorted+=("${line}")
done < <(printf '%s\n' "${samples[@]}" | sort -n)
count="${#sorted[@]}"
min="${sorted[0]}"
max="${sorted[$((count - 1))]}"
median="${sorted[$((count / 2))]}"
spread="$(awk -v a="${max}" -v b="${min}" 'BEGIN { printf "%.1f", a - b }')"

echo ""
echo "样本数 ${count}　最小 ${min}%　中位数 ${median}%　最大 ${max}%"
echo "本次波动范围 ${spread} 个百分点 —— 这是**本方法的噪声下限**"

# 全是 0 说明当时没有音频流过（这个指标只在有音频时才有意义）
all_zero=1
for value in ${samples[@]+"${samples[@]}"}; do
    if [[ "${value}" != "0.0" && "${value}" != "0" ]]; then all_zero=0; fi
done
if [[ "${all_zero}" == "1" ]]; then
    echo ""
    echo "⚠️ 所有样本都是 0% —— 极可能当时**没有音频在播放**。"
    echo "   coreaudiod 只有在真正搬运音频时才有开销；请播放同一音源后再测，"
    echo "   并保证两次对比时播放条件完全一致。"
fi

echo ""
echo "判读：两次配置的中位数差异明显大于上面的波动范围，才算真有差异；"
echo "      否则请加长采样时间或增加配对轮次，不要凭单次读数下结论。"
echo ""
echo "说明：ps 的 %cpu 是内核的**衰减平均值**（带历史权重、故会小幅波动），"
echo "      它适合**配对比较**（同一会话内 A/B 交替），不宜当作瞬时读数。"
echo "      本次已预热 ${WARMUP_SECONDS} 秒；两次对比请使用**相同的预热设置**。"
