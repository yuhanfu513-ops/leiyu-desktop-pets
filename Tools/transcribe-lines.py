from pathlib import Path
import json,wave,numpy as np
from faster_whisper import WhisperModel
cache=Path.home()/'.cache/leiyu-audio-models'
cache.mkdir(parents=True,exist_ok=True)
model=WhisperModel('small',device='cpu',compute_type='int8',cpu_threads=8,download_root=str(cache/'whisper'))
with wave.open('Work/audio-analysis/source16.wav') as w:
 assert w.getframerate()==16000 and w.getnchannels()==1
 a=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16).astype(np.float32)/32768
segments,_=model.transcribe(a,language='zh',word_timestamps=True,beam_size=5,condition_on_previous_text=False,vad_filter=True)
rows=[]
for s in segments:
 row={'start':s.start,'end':s.end,'text':s.text,'words':[{'start':w.start,'end':w.end,'word':w.word} for w in (s.words or [])]}
 rows.append(row);print(json.dumps(row,ensure_ascii=False),flush=True)
Path('Work/audio-analysis/transcript.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
