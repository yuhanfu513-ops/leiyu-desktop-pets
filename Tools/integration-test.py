"""Exercise both real app processes in an isolated, silent test session.

The two pets now play per-speaker sentence clips.  This test checks that:
  * each app only loads its own speaker's clips and subtitles;
  * clicking one pet animates and captions only that pet;
  * a second click takes over the single shared audio channel;
  * approaching makes both heads lean toward each other without playing audio;
  * a speaking pet keeps bouncing while both heads stay tilted;
  * stop and quit behave as expected.
"""
import json
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

root = Path(__file__).resolve().parents[1]
apps = {
    "lei": root / "build/雷军桌宠.app/Contents/MacOS/LeiYuPet",
    "yu": root / "build/余承东桌宠.app/Contents/MacOS/LeiYuPet",
}
resources = {role: exe.parents[1] / "Resources" for role, exe in apps.items()}
all_clips = json.loads((resources["lei"] / "clips.json").read_text(encoding="utf-8"))
helium_clips = json.loads((resources["lei"] / "clips-helium.json").read_text(encoding="utf-8"))
clips = {role: sorted((c for c in all_clips if c["role"] == role), key=lambda c: c["duration"]) for role in apps}
clip_by_id = {c["id"]: c for c in all_clips}
helium_by_id = {c["id"]: c for c in helium_clips}
pairs = json.loads((resources["lei"] / "pairs.json").read_text(encoding="utf-8"))
checks = []

with tempfile.TemporaryDirectory(prefix="leiyu-test-") as tmp:
    work = Path(tmp)
    processes = {}

    def state(role):
        try:
            return json.loads((work / (role + ".json")).read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def command(role, action, **kwargs):
        path = work / (role + "-command.json")
        temp = path.with_suffix(".tmp")
        temp.write_text(json.dumps({"id": str(uuid.uuid4()), "action": action, **kwargs}), encoding="utf-8")
        temp.replace(path)

    def wait(label, condition, timeout=6):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if condition():
                checks.append(label)
                print("OK", label, flush=True)
                return
            time.sleep(0.08)
        raise AssertionError(
            label + "; lei=" + json.dumps(state("lei"), ensure_ascii=False) +
            "; yu=" + json.dumps(state("yu"), ensure_ascii=False)
        )

    def move_gap(gap):
        """Place Yu to the right of Lei's portrait with the given edge gap."""
        a = state("lei")
        command("yu", "move", x=a["x"] + a["width"] + gap - 48, y=a["y"] - 16)

    def tilted():
        return state("lei").get("angle", 0) < -0.05 and state("yu").get("angle", 0) > 0.05

    def upright():
        if abs(state("lei").get("angle", 1)) >= 0.02:
            return False
        peer = state("yu")
        return not peer or abs(peer.get("angle", 1)) < 0.02

    try:
        assert set(c["role"] for c in all_clips) == {"lei", "yu"}
        assert all((resources[c["role"]] / "Clips" / c["file"]).is_file() for c in all_clips)
        assert all(c["text"] and c["duration"] > 0.2 for c in all_clips)
        assert all(c.get("lines") and all(line["text"] for line in c["lines"]) for c in all_clips)
        assert len({c["id"] for c in all_clips}) == len(all_clips)
        assert len(pairs) == 8
        assert all(clip_by_id[p["lei"]]["role"] == "lei" and clip_by_id[p["yu"]]["role"] == "yu" for p in pairs)
        assert all(helium_by_id[p["lei"]]["role"] == "lei" and helium_by_id[p["yu"]]["role"] == "yu" for p in pairs)
        assert (resources["yu"] / "pairs.json").is_file()
        assert len(helium_clips) == len(all_clips)
        assert [c["id"] for c in helium_clips] == [c["id"] for c in all_clips]
        assert [c["text"] for c in helium_clips] == [c["text"] for c in all_clips]
        assert all((resources[c["role"]] / "Clips-helium" / c["file"]).is_file() for c in helium_clips)
        assert all(c["text"] and c["duration"] > 0.2 for c in helium_clips)
        assert all(c.get("lines") and all(line["text"] for line in c["lines"]) for c in helium_clips)
        assert all(c["duration"] <= clip_by_id[c["id"]]["duration"] + 0.01 for c in helium_clips)
        print("OK clips metadata: %d lei + %d yu, normal and helium files present" % (len(clips["lei"]), len(clips["yu"])), flush=True)
        print("OK dialogue pairs: %d, shared by both voices" % len(pairs), flush=True)
        checks.append("clips metadata split by speaker, normal + helium")
        checks.append("dialogue pairs metadata")

        for role, exe in apps.items():
            processes[role] = subprocess.Popen(
                [str(exe), "--integration-test", str(work)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
        wait("Both independent applications publish live state", lambda: all(state(r) for r in apps), 10)
        time.sleep(0.5)

        assert not state("lei")["playing"] and not state("lei")["animating"] and not state("lei")["subtitle"]
        assert not state("yu")["playing"] and not state("yu")["animating"] and not state("yu")["subtitle"]
        assert not state("lei").get("helium") and not state("yu").get("helium")
        print("OK both pets start idle in the normal voice", flush=True)
        checks.append("both pets start idle")

        lei_mid = next(c for c in clips["lei"] if c["duration"] >= 2.0)
        command("lei", "click", clipID=lei_mid["id"])
        wait(
            "Clicking Lei plays only Lei with its subtitle",
            lambda: state("lei").get("playing")
            and state("lei").get("animating")
            and state("lei").get("subtitle") == lei_mid["text"]
            and not state("yu").get("playing")
            and not state("yu").get("animating")
            and not state("yu").get("subtitle"),
            4,
        )
        wait("Lei's subtitle disappears after the line", lambda: not state("lei").get("subtitle"), 6)
        assert state("lei")["plays"] == 1 and not state("yu")["playing"]
        print("OK Lei line finished without moving Yu", flush=True)
        checks.append("Lei line finishes without moving Yu")

        yu_mid = next(c for c in clips["yu"] if c["duration"] >= 2.0)
        command("yu", "click", clipID=yu_mid["id"])
        wait(
            "Clicking Yu plays only Yu with its subtitle",
            lambda: state("yu").get("playing")
            and state("yu").get("animating")
            and state("yu").get("subtitle") == yu_mid["text"]
            and not state("lei").get("playing")
            and not state("lei").get("animating")
            and not state("lei").get("subtitle"),
            4,
        )
        wait("Yu's subtitle disappears after the line", lambda: not state("yu").get("subtitle"), 6)
        print("OK Yu line finished without moving Lei", flush=True)
        checks.append("Yu line finishes without moving Lei")

        yu_accident = next(c for c in clips["yu"] if c["lines"][0]["text"].startswith("漂移就是"))
        accident_parts = yu_accident["lines"]
        command("yu", "click", clipID=yu_accident["id"])
        wait(
            "Yu starts the accident clip with its first subtitle",
            lambda: state("yu").get("playing")
            and state("yu").get("clipID") == yu_accident["id"]
            and state("yu").get("subtitle") == accident_parts[0]["text"],
            3,
        )
        wait("Yu's accident subtitle advances to 我说那是一个最愚蠢的行为", lambda: state("yu").get("subtitle") == accident_parts[1]["text"], 5)
        command("yu", "stop")
        wait("Stopping the accident clip clears its subtitle", lambda: not state("yu").get("playing") and not state("yu").get("subtitle"), 4)

        lei_belief = next(c for c in clips["lei"] if c["lines"][0]["text"].startswith("但我相信"))
        belief_parts = lei_belief["lines"]
        command("lei", "click", clipID=lei_belief["id"])
        wait(
            "Lei starts the belief clip with its first subtitle",
            lambda: state("lei").get("playing")
            and state("lei").get("clipID") == lei_belief["id"]
            and state("lei").get("subtitle") == belief_parts[0]["text"],
            3,
        )
        wait("Lei's belief subtitle advances to 后来者总有机会", lambda: state("lei").get("subtitle") == belief_parts[1]["text"], 8)
        command("lei", "stop")
        wait("Stopping the belief clip clears its subtitle", lambda: not state("lei").get("playing") and not state("lei").get("subtitle"), 4)

        lei_specs = next(c for c in clips["lei"] if c["lines"][0]["text"].startswith("最大马力"))
        spec_parts = lei_specs["lines"]
        command("lei", "click", clipID=lei_specs["id"])
        wait(
            "Lei starts the specs clip with 最大马力",
            lambda: state("lei").get("playing")
            and state("lei").get("clipID") == lei_specs["id"]
            and state("lei").get("subtitle") == spec_parts[0]["text"],
            3,
        )
        wait("Lei's spec subtitle advances to 零百加速", lambda: state("lei").get("subtitle") == spec_parts[1]["text"], 6)
        command("lei", "stop")
        wait("Stopping the specs clip clears its subtitle", lambda: not state("lei").get("playing") and not state("lei").get("subtitle"), 4)

        yu_long = clips["yu"][-1]
        lei_short = clips["lei"][0]
        subtitle_lines = yu_long["lines"]
        command("yu", "click", clipID=yu_long["id"])
        wait(
            "Yu starts the merged longer line with its first subtitle",
            lambda: state("yu").get("playing")
            and state("yu").get("clipID") == yu_long["id"]
            and state("yu").get("subtitle") == subtitle_lines[0]["text"],
            3,
        )
        wait("The subtitle advances to the second sentence", lambda: state("yu").get("subtitle") == subtitle_lines[1]["text"], 4)
        wait("The subtitle advances to the third sentence", lambda: state("yu").get("subtitle") == subtitle_lines[2]["text"], 5)
        command("lei", "click", clipID=lei_short["id"])
        wait(
            "A second click takes over the single audio channel",
            lambda: state("lei").get("playing")
            and state("lei").get("subtitle") == lei_short["text"]
            and not state("yu").get("playing")
            and not state("yu").get("animating")
            and not state("yu").get("subtitle"),
            4,
        )
        wait("The taking-over line finishes", lambda: not state("lei").get("playing"), 4)

        plays_before = state("lei")["plays"]
        move_gap(8)
        wait("Approaching tilts both heads toward each other", tilted, 5)
        assert not state("lei")["playing"] and not state("yu")["playing"] and state("lei")["plays"] == plays_before
        print("OK approaching does not auto-play audio", flush=True)
        checks.append("approaching tilts without auto-play")

        move_gap(200)
        wait("Separating straightens both heads", upright, 5)

        move_gap(8)
        wait("Near again before speaking", tilted, 5)
        command("lei", "click", clipID=lei_mid["id"])
        wait(
            "The speaking pet bounces while both heads stay tilted",
            lambda: state("lei").get("animating")
            and state("lei").get("angle", 0) < -0.05
            and state("yu").get("angle", 0) > 0.05
            and not state("yu").get("animating"),
            4,
        )
        wait("Lei line finishes while still near", lambda: not state("lei").get("playing"), 6)

        duet_one = pairs[0]
        duet_two = min(
            (p for p in pairs if clip_by_id[p["lei"]]["duration"] >= 2.0),
            key=lambda p: clip_by_id[p["lei"]]["duration"] + clip_by_id[p["yu"]]["duration"],
        )
        one_lei, one_yu = clip_by_id[duet_one["lei"]], clip_by_id[duet_one["yu"]]
        two_lei, two_yu = clip_by_id[duet_two["lei"]], clip_by_id[duet_two["yu"]]

        command("yu", "pair", pairID=duet_one["id"])
        wait(
            "Yu initiating a duet makes Lei speak first",
            lambda: state("lei").get("playing")
            and state("lei").get("clipID") == one_lei["id"]
            and state("lei").get("subtitle") == one_lei["lines"][0]["text"]
            and not state("yu").get("playing"),
            4,
        )
        wait(
            "Lei hands the duet to Yu",
            lambda: state("yu").get("playing")
            and state("yu").get("clipID") == one_yu["id"]
            and state("yu").get("subtitle") == one_yu["lines"][0]["text"]
            and not state("lei").get("playing"),
            7,
        )
        wait("The Yu-initiated duet finishes", lambda: not state("lei").get("playing") and not state("yu").get("playing"), 7)

        command("lei", "pair", pairID=duet_two["id"])
        wait(
            "Lei initiating a duet still speaks first",
            lambda: state("lei").get("playing")
            and state("lei").get("clipID") == two_lei["id"]
            and not state("yu").get("playing"),
            4,
        )
        wait(
            "The Lei-initiated duet moves to Yu",
            lambda: state("yu").get("playing")
            and state("yu").get("clipID") == two_yu["id"]
            and not state("lei").get("playing"),
            5,
        )
        wait("The Lei-initiated duet finishes", lambda: not state("lei").get("playing") and not state("yu").get("playing"), 5)

        command("lei", "click")
        wait(
            "A near click starts the duet with Lei",
            lambda: state("lei").get("playing") and not state("yu").get("playing"),
            3,
        )
        command("lei", "stop")
        wait(
            "Stopping the near-click duet clears both",
            lambda: not state("lei").get("playing")
            and not state("yu").get("playing")
            and not state("lei").get("subtitle")
            and not state("yu").get("subtitle"),
            4,
        )

        command("lei", "voice", helium=True)
        wait(
            "Both pets switch to the 1.5x helium voice",
            lambda: state("lei").get("helium") and state("yu").get("helium"),
            4,
        )
        helium_short = next(c for c in helium_clips if c["role"] == "yu" and c["duration"] >= 1.5)
        command("yu", "click", clipID=helium_short["id"])
        wait(
            "A helium clip plays with its subtitle",
            lambda: state("yu").get("playing")
            and state("yu").get("clipID") == helium_short["id"]
            and state("yu").get("subtitle") == helium_short["lines"][0]["text"]
            and not state("lei").get("playing"),
            3,
        )
        command("yu", "stop")
        wait("Stopping the helium clip clears it", lambda: not state("yu").get("playing") and not state("yu").get("subtitle"), 4)

        helium_pair = pairs[2]
        hp_lei, hp_yu = helium_by_id[helium_pair["lei"]], helium_by_id[helium_pair["yu"]]
        command("lei", "pair", pairID=helium_pair["id"])
        wait(
            "A helium duet still starts with Lei",
            lambda: state("lei").get("playing")
            and state("lei").get("clipID") == hp_lei["id"]
            and state("lei").get("helium")
            and not state("yu").get("playing"),
            4,
        )
        wait(
            "The helium duet moves to Yu",
            lambda: state("yu").get("playing")
            and state("yu").get("clipID") == hp_yu["id"]
            and state("yu").get("helium")
            and not state("lei").get("playing"),
            5,
        )
        wait("The helium duet finishes", lambda: not state("lei").get("playing") and not state("yu").get("playing"), 5)

        command("lei", "voice", helium=False)
        wait(
            "Both pets switch back to the normal voice",
            lambda: not state("lei").get("helium") and not state("yu").get("helium"),
            4,
        )

        move_gap(200)
        wait("Separating after speaking straightens both heads", upright, 5)

        command("yu", "click", clipID=yu_long["id"])
        wait("Yu starts a line to stop", lambda: state("yu").get("playing"), 3)
        command("lei", "stop")
        wait(
            "Stop silences both apps and clears subtitles",
            lambda: not state("lei").get("playing")
            and not state("yu").get("playing")
            and not state("lei").get("subtitle")
            and not state("yu").get("subtitle"),
            4,
        )

        move_gap(8)
        wait("Near before quitting", tilted, 5)
        command("yu", "click", clipID=yu_long["id"])
        wait("Yu is speaking before quit", lambda: state("yu").get("playing"), 3)
        command("yu", "quit")
        wait(
            "Closing Yu stops its own audio and straightens Lei",
            lambda: processes["yu"].poll() is not None and upright(),
            7,
        )
        assert not state("lei")["playing"]

        results = {
            "result": "PASS",
            "checks": checks,
            "clips": {"lei": len(clips["lei"]), "yu": len(clips["yu"])},
            "pairs": len(pairs),
            "voices": {"normal": len(all_clips), "helium": len(helium_clips)},
        }
        results_path = root / "Work/integration-results.json"
        results_path.parent.mkdir(parents=True, exist_ok=True)
        results_path.write_text(
            json.dumps(results, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print("PASS", flush=True)
    finally:
        for role, process in processes.items():
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            error = process.stderr.read().decode(errors="replace")
            if error:
                print(role + " stderr:", error[-1200:], flush=True)
