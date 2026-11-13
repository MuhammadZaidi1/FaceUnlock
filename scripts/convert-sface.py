#!/usr/bin/env python3
"""Convert the checksum-pinned OpenCV SFace ONNX weights and verify CPU parity.
This is a narrow translator for this exact graph, not a general ONNX converter.
No faces, camera data, or production enrollment vectors are used.
"""
import hashlib
import json
from pathlib import Path
import numpy as np
import onnx
import onnxruntime as ort
import coremltools as ct
from coremltools.converters.mil import Builder as mb

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / '.model-work/sface.onnx'
DEST = ROOT / 'Sources/FaceModel/Models'
SHA = '0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79'
assert hashlib.sha256(SOURCE.read_bytes()).hexdigest() == SHA, 'Unrecognized source weights'
graph = onnx.load(SOURCE).graph
constants = {t.name: onnx.numpy_helper.to_array(t).copy() for t in graph.initializer}

@mb.program(input_specs=[mb.TensorSpec(shape=(1, 3, 112, 112))], opset_version=ct.target.macOS13)
def program(face):
    values = dict(constants)
    values['data'] = face
    for index, node in enumerate(graph.node):
        inputs = [values[n] for n in node.input]
        attrs = {a.name: onnx.helper.get_attribute_value(a) for a in node.attribute}
        x = inputs[0]
        name = f'sface_{index}'
        if node.op_type == 'Sub':
            y = mb.sub(x=x, y=inputs[1], name=name)
        elif node.op_type == 'Mul':
            y = mb.mul(x=x, y=inputs[1], name=name)
        elif node.op_type == 'Conv':
            pads = attrs.get('pads', [0, 0, 0, 0])
            y = mb.conv(x=x, weight=inputs[1], strides=attrs.get('strides', [1, 1]),
                        pad_type='custom', pad=[pads[0], pads[2], pads[1], pads[3]],
                        dilations=attrs.get('dilations', [1, 1]), groups=attrs.get('group', 1), name=name)
        elif node.op_type == 'BatchNormalization':
            gamma, beta, mean, var = inputs[1:]
            scale = gamma / np.sqrt(var + attrs.get('epsilon', 1e-5))
            offset = beta - mean * scale
            shape = (1, len(scale)) + (1,) * (len(x.shape) - 2)
            y = mb.add(x=mb.mul(x=x, y=scale.reshape(shape)), y=offset.reshape(shape), name=name)
        elif node.op_type == 'PRelu':
            y = mb.prelu(x=x, alpha=inputs[1].reshape(-1), name=name)
        elif node.op_type == 'Dropout':
            y = mb.identity(x=x, name=name)
        elif node.op_type == 'Flatten':
            axis = attrs.get('axis', 1)
            y = mb.reshape(x=x, shape=[int(np.prod(x.shape[:axis])), int(np.prod(x.shape[axis:]))], name=name)
        elif node.op_type == 'Gemm':
            assert attrs.get('transA', 0) == 0 and attrs.get('transB', 0) == 1
            assert attrs.get('alpha', 1) == 1 and attrs.get('beta', 1) == 1
            y = mb.linear(x=x, weight=inputs[1], bias=inputs[2], name=name)
        else:
            raise ValueError(f'Unsupported operator: {node.op_type}')
        values[node.output[0]] = y
    return mb.identity(x=values['fc1'], name='embedding')

model = ct.convert(program, convert_to='mlprogram', minimum_deployment_target=ct.target.macOS13,
                   compute_precision=ct.precision.FLOAT32, compute_units=ct.ComputeUnit.CPU_ONLY)
model.author = 'OpenCV Zoo / Yaoyao Zhong; Core ML conversion by FaceUnlock'
model.license = 'Apache-2.0; see SFace-LICENSE.txt'
model.short_description = 'SFace 2021dec MobileFaceNet; RGB NCHW 0..255; output 128-dimensional identity embedding'
model.version = '2021dec-pipeline1-fp32'
model.input_description['face'] = 'Aligned RGB float32 [1,3,112,112], 0..255. Normalization is inside the graph.'
model.output_description['embedding'] = '128-dimensional raw SFace output; L2 normalize before cosine comparison.'

options = ort.SessionOptions()
options.log_severity_level = 3
session = ort.InferenceSession(str(SOURCE), sess_options=options, providers=['CPUExecutionProvider'])
# Deterministic synthetic arrays, not fake production embeddings or saved user data.
indices = np.arange(3 * 112 * 112)
fixtures = [np.zeros((1,3,112,112), np.float32), np.full((1,3,112,112), 127, np.float32),
            ((indices * 37 + indices // 112) % 256).astype(np.float32).reshape(1,3,112,112),
            ((indices // 8 % 2) * 200 + 20).astype(np.float32).reshape(1,3,112,112)]
report = []
for number, data in enumerate(fixtures):
    expected = session.run(None, {'data': data})[0].reshape(-1)
    actual = model.predict({'face': data})['embedding'].reshape(-1)
    assert expected.shape == actual.shape == (128,)
    assert np.isfinite(actual).all()
    cosine = float(np.dot(actual, expected) / (np.linalg.norm(actual) * np.linalg.norm(expected)))
    error = float(np.max(np.abs(actual - expected)))
    assert cosine > .99999 and np.allclose(actual, expected, rtol=0.005, atol=0.005), (number, cosine, error)
    report.append({'synthetic_fixture': number, 'cosine_to_onnx': cosine, 'maximum_absolute_error': error})
    print(f'PASS fixture {number}: Core ML vs ONNX cosine {cosine:.8f}, max abs error {error:.7f}')

DEST.mkdir(parents=True, exist_ok=True)
package = DEST / 'SFace.mlpackage'
model.save(str(package))

def package_hash(path):
    digest = hashlib.sha256()
    for child in sorted(p for p in path.rglob('*') if p.is_file()):
        digest.update(child.relative_to(path).as_posix().encode() + b'\0')
        digest.update(child.read_bytes())
    return digest.hexdigest()

manifest = {'model': 'SFace-2021dec-CoreML-fp32', 'source_sha256': SHA,
            'coreml_sha256': package_hash(package), 'pipeline_version': 1,
            'source_url': 'https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface',
            'input': {'name': 'face', 'shape': [1,3,112,112], 'dtype': 'float32', 'range': [0,255], 'order': 'RGB'},
            'output': {'name': 'embedding', 'shape': [1,128], 'dtype': 'float32'},
            'license': 'Apache-2.0', 'coremltools': ct.__version__, 'conversion_parity': report}
(DEST / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('Saved and validated licensed real SFace Core ML package.')
