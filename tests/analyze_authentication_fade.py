#!/usr/bin/env python3
"""Measure blur/dim transitions in synthetic AUTH-A screencopy frames."""
import json
from pathlib import Path
import statistics
import subprocess
import sys


def analyze_recording(work, events):
    frames = [json.loads(line.split('AUTH_RECORDED ', 1)[1])
              for line in (work / 'recording.log').read_text().splitlines()
              if 'AUTH_RECORDED ' in line]
    samples = []
    for frame in frames:
        if frame['time'] > events['escape_ms'] + 1600:
            continue
        path = work / 'frames' / f"frame-{frame['index']}.png"
        # Stripe background outside the centered card, in the recorder's crop.
        values = subprocess.check_output(['magick', str(path), '-crop', '50x250+5+60',
            '-colorspace', 'gray', '-format', '%[fx:mean] %[fx:standard_deviation]', 'info:'], text=True)
        mean, deviation = map(float, values.split())
        samples.append(dict(frame, mean=mean, deviation=deviation,
                            after_escape_ms=frame['time'] - events['escape_ms']))
    clear = max(f['deviation'] for f in samples)
    blurred = min(f['deviation'] for f in samples)
    assert clear > blurred * 2, ('Synthetic stripes must show a measurable blur', clear, blurred)
    for frame in samples:
        # Normalized contrast loss includes blur and dimming; it does not infer
        # the compositor's blur radius or claim to measure the live desktop FPS.
        frame['contrast_loss'] = round((clear - frame['deviation']) / (clear - blurred), 4)
    entering = [f for f in samples if events['request_ms'] <= f['time'] < events['escape_ms']]
    leaving = [f for f in samples if f['after_escape_ms'] >= 0]
    transition = [f for f in samples if events['request_ms'] <= f['time'] <= events['escape_ms'] + 250]
    gaps = [b['time'] - a['time'] for a, b in zip(transition, transition[1:])]
    steps = [a['contrast_loss'] - b['contrast_loss'] for a, b in zip(leaving, leaving[1:])]
    result = dict(clear_deviation=clear, blurred_deviation=blurred,
        recorded_frames=len(frames),
        intermediate_entrance_frames=sum(0.1 < f['contrast_loss'] < 0.9 for f in entering),
        intermediate_exit_frames=sum(0.1 < f['contrast_loss'] < 0.9 for f in leaving),
        max_transition_gap_ms=max(gaps), median_transition_gap_ms=statistics.median(gaps),
        largest_exit_step=round(max(map(abs, steps)), 4),
        largest_exit_reversal=round(max(0, -min(steps)), 4))
    (work / 'composed-pixel-check.json').write_text(json.dumps(dict(result, samples=samples), indent=2))
    return result


if __name__ == '__main__':
    work = Path(sys.argv[1])
    events = json.loads((work / 'result.json').read_text())['recording_events']
    print(json.dumps(analyze_recording(work, events), indent=2))
