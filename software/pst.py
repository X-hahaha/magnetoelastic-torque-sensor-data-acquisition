#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pst —— plot_sensor_timeline 的终端快捷入口

省掉每次手敲那串长路径。默认取【最新的一个采集帧】，也可以按帧号挑。

用法
----
    pst                        # 最新一帧，画 l2_um
    pst 688                    # 帧号含 688 的最新一帧
    pst 000688 -c l3_um        # 换通道
    pst 688 --serve            # 起本地服务并打开浏览器
    pst 688 -o D:/tmp/x.html   # 指定输出
    pst --list                 # 列出最近 10 个可用帧
    pst --list 25              # 列出最近 25 个
    pst --all --list           # 连 calibration_* 一起列
    pst D:/path/to/frame_000688_sensor_timeline.csv   # 直接给文件路径

`--` 之后的所有参数原样转交给 plot_sensor_timeline.py。

采集目录默认是 <本脚本所在目录>/captures，可用环境变量 DS_CAPTURES 覆盖。
默认只认 capture_* 目录、且文件不小于 2 KB —— calibration_* 里也有同名的
_sensor_timeline.csv，但只有 100 来字节、没有数据行，会把"最新一帧"顶掉。
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CAPTURES = os.environ.get("DS_CAPTURES") or os.path.join(HERE, "captures")
PLOTTER = os.path.join(HERE, "plot_sensor_timeline.py")
SUFFIX = "_sensor_timeline.csv"
MIN_BYTES = 2048          # calibration_* 目录里的同名文件只有 100 来字节，没有数据行
INCLUDE_ALL = False       # --all 时连 calibration_* 一起列


def find_all():
    """返回 [(mtime, path)]，按时间倒序（最新在前）。

    默认只看 capture_* 目录、且文件不小于 MIN_BYTES —— 否则 calibration_* 里的
    空壳文件会把"最新一帧"顶掉，一路跑到绘图脚本才报"CSV 里没有数据行"。
    """
    hits = []
    if not os.path.isdir(CAPTURES):
        return hits
    for root, _dirs, files in os.walk(CAPTURES):
        top = os.path.relpath(root, CAPTURES).split(os.sep)[0]
        if not INCLUDE_ALL and not top.startswith("capture_"):
            continue
        for f in files:
            if not f.endswith(SUFFIX):
                continue
            p = os.path.join(root, f)
            try:
                sz = os.path.getsize(p)
            except OSError:
                continue
            if not INCLUDE_ALL and sz < MIN_BYTES:
                continue
            hits.append((os.path.getmtime(p), p))
    hits.sort(key=lambda x: x[0], reverse=True)
    return hits


def human(ts):
    import time
    return time.strftime("%m-%d %H:%M:%S", time.localtime(ts))


def pick(token):
    """按 token 选一帧。token 可以是帧号、帧号片段、capture 目录名，或完整路径。"""
    if os.path.sep in token or token.endswith(".csv"):
        if os.path.isfile(token):
            return os.path.abspath(token)
        raise SystemExit("找不到文件：%s" % token)

    allf = find_all()
    if not allf:
        raise SystemExit("在 %s 下没找到 *%s\n（可用环境变量 DS_CAPTURES 指定采集目录）"
                         % (CAPTURES, SUFFIX))

    if token.isdigit():
        want = "frame_%06d%s" % (int(token), SUFFIX)
        for _ts, p in allf:                       # 精确命中优先
            if os.path.basename(p) == want:
                return p
    low = token.lower()
    for _ts, p in allf:                           # 再按子串匹配（帧号片段 / capture 目录名）
        if low in p.lower():
            return p
    raise SystemExit("没找到匹配 %r 的帧。用 `pst --list` 看有哪些。" % token)


def list_frames(n):
    allf = find_all()
    if not allf:
        raise SystemExit("在 %s 下没找到可用的 *%s" % (CAPTURES, SUFFIX))
    print("采集目录：%s" % CAPTURES)
    print("%-3s %-17s %-15s %9s  %s" % ("#", "时间", "帧", "大小", "采集"))
    for i, (ts, p) in enumerate(allf[:n], 1):
        frame = os.path.basename(p).replace(SUFFIX, "")
        cap = os.path.basename(os.path.dirname(p))
        print("%-3d %-17s %-15s %8.1fK  %s"
              % (i, human(ts), frame, os.path.getsize(p) / 1024.0, cap))
    if len(allf) > n:
        print("…… 共 %d 帧，只列了最近 %d 个（--all 可包含 calibration_*）"
              % (len(allf), n))


def main():
    global INCLUDE_ALL
    argv = sys.argv[1:]
    if not os.path.isfile(PLOTTER):
        raise SystemExit("找不到 plot_sensor_timeline.py（应在 %s）" % PLOTTER)

    if argv and argv[0] in ("-h", "--help"):
        print(__doc__)
        return

    if "--all" in argv:
        INCLUDE_ALL = True
        argv = [x for x in argv if x != "--all"]

    if argv and argv[0] == "--list":
        n = 10
        if len(argv) > 1 and argv[1].isdigit():
            n = int(argv[1])
        list_frames(n)
        return

    token, rest = None, argv
    if argv and not argv[0].startswith("-"):
        token, rest = argv[0], argv[1:]

    if token is None:
        allf = find_all()
        if not allf:
            raise SystemExit("在 %s 下没找到 *%s" % (CAPTURES, SUFFIX))
        csv = allf[0][1]
        print("（未指定帧，用最新的）")
    else:
        csv = pick(token)

    print("帧文件：%s" % csv)
    cmd = [sys.executable, PLOTTER, csv] + rest
    sys.exit(subprocess.call(cmd))


if __name__ == "__main__":
    main()
