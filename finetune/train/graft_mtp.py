"""Graft RhymeAI-tuned tensors onto the stock Qwen3.5-4B BF16 GGUF.

transformers' Qwen3_5ForConditionalGeneration doesn't model the MTP draft
layer, so the PEFT-merged checkpoint converts with metadata that llama.cpp
rejects (config still declares num_nextn_predict_layers=1 -> block_count 33,
but only 32 layers of tensors exist: "missing tensor blk.32.attn_norm.weight").
The stock GGUF has the correct metadata (MTP stripped; unsloth ships it as a
separate -MTP-GGUF repo). The LoRA never targeted MTP, so the right artifact
is: stock metadata + tuned tensors. This script asserts the tensor name sets
match exactly and every shape/dtype agrees.

Usage: graft_mtp.py <stock_bf16.gguf> <tuned_bf16.gguf> <out.gguf> [gguf_py_dir]
"""
import os
import sys

sys.path.insert(0, sys.argv[4] if len(sys.argv) > 4
                else os.path.expanduser("~/src/llama.cpp/gguf-py"))
from gguf import GGUFReader, GGUFWriter, GGUFValueType  # noqa: E402

stock_path, tuned_path, out_path = sys.argv[1:4]
stock = GGUFReader(stock_path)
tuned = GGUFReader(tuned_path)
tuned_tensors = {t.name: t for t in tuned.tensors}
stock_names = {t.name for t in stock.tensors}
assert stock_names == set(tuned_tensors), (
    "tensor sets diverge; stock-only=%s tuned-only=%s" % (
        sorted(stock_names - set(tuned_tensors))[:5],
        sorted(set(tuned_tensors) - stock_names)[:5]))

arch = str(stock.fields["general.architecture"].contents())
writer = GGUFWriter(out_path, arch)

VIRTUAL = ("GGUF.version", "GGUF.tensor_count", "GGUF.kv_count")
for key, field in stock.fields.items():
    if key in VIRTUAL or key == "general.architecture":
        continue
    val = field.contents()
    if field.types[0] == GGUFValueType.ARRAY:
        writer.add_array(key, val)
    else:
        writer.add_key_value(key, val, field.types[0])

for t in stock.tensors:
    src = tuned_tensors[t.name]
    assert tuple(src.shape) == tuple(t.shape), f"shape mismatch: {t.name}"
    assert src.tensor_type == t.tensor_type, f"dtype mismatch: {t.name}"
    writer.add_tensor(src.name, src.data, raw_dtype=src.tensor_type)

writer.write_header_to_file()
writer.write_kv_data_to_file()
writer.write_tensors_to_file(progress=True)
writer.close()
print(f"grafted {len(tuned_tensors)} tuned tensors under stock metadata -> {out_path}")
