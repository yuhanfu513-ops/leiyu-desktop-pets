from pathlib import Path
import sherpa_onnx, json, wave, numpy as np
cache=Path.home()/'.cache/leiyu-audio-models'
config=sherpa_onnx.OfflineSpeakerDiarizationConfig(
 segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(cache/'sherpa-onnx-pyannote-segmentation-3-0/model.onnx'),window_shift_ratio=0.1),num_threads=4),
 embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(cache/'campplus.onnx'),num_threads=4),
 clustering=sherpa_onnx.FastClusteringConfig(num_clusters=2),min_duration_on=.15,min_duration_off=.12)
assert config.validate()
with wave.open('Work/audio-analysis/source16.wav') as w:
 assert w.getframerate()==16000
 audio=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16).astype(np.float32)/32768
sd=sherpa_onnx.OfflineSpeakerDiarization(config)
rows=[]
for r in sd.process(audio).sort_by_start_time():
 rows.append({'start':r.start,'end':r.end,'speaker':r.speaker})
first=rows[0]['speaker']
for r in rows:
 r['role']='lei' if r['speaker']==first else 'yu'
 print(json.dumps(r),flush=True)
Path('Work/audio-analysis/diarization.json').write_text(json.dumps(rows,indent=2))
