"""Validation and replay parameters for native local-model contract exports."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re


class ContractError(ValueError):
    pass


PLATFORMS = {"ios", "android"}
REQUEST_KINDS = {"suggestions", "rewrite_passage", "rewrite_word", "synonyms"}
TERMINATION_REASONS = {
    "notRun",
    "eog",
    "stopSequence",
    "maximumOutputTokens",
    "maximumResponseLength",
    "contextExhausted",
    "deadline",
    "cancelled",
    "error",
}
SHA1_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
CASE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*$")

TOP_KEYS = {
    "schemaVersion", "platform", "sourceSha", "modelSha256", "caseId",
    "requestKind", "request", "prompt", "generation", "runtime",
}
REQUEST_KEYS = {"controls", "localContext"}
PROMPT_KEYS = {
    "userText", "renderedText", "userTextSha256", "renderedTextSha256",
    "tokenizerArchitecture", "tokenizerEnvelope",
    "tokenizerChatTemplateSha256", "tokenization",
}
TOKENIZATION_KEYS = {"addSpecial", "parseSpecial"}
GENERATION_KEYS = {"engine", "contextLength", "sampler", "termination", "cache"}
ENGINE_KEYS = {"name", "version"}
SAMPLER_KEYS = {"chain", "seed"}
SEED_KEYS = {"policy", "value"}
SAMPLER_STAGE_KEYS = {"algorithm", "parameters"}
TERMINATION_KEYS = {
    "stopOnEog", "stopSequences", "maximumOutputTokens",
    "maximumResponseLength", "responseLengthUnit", "deadlineMs", "reason",
}
CACHE_KEYS = {"clearKvBeforeRequest", "promptCache", "state"}
RUNTIME_KEYS = {"target", "osVersion", "buildVariant", "evidenceKind", "capturedAt"}

SAMPLER_PARAMETERS = {
    "penalties": {
        "lastN", "repeat", "frequency", "presence", "penalizeNewline",
    },
    "topK": {"k"},
    "topP": {"p", "minimumKeep"},
    "minP": {"p", "minimumKeep"},
    "typicalP": {"p", "minimumKeep"},
    "tailFree": {"z", "minimumKeep"},
    "xtc": {"probability", "threshold", "minimumKeep"},
    "temperature": {"value"},
    "distribution": set(),
}


def _fail(path, message):
    raise ContractError("%s: %s" % (path, message))


def _object(value, path):
    if not isinstance(value, dict):
        _fail(path, "must be an object")
    return value


def _exact_keys(value, expected, path):
    actual = set(_object(value, path))
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    if missing or extra:
        parts = []
        if missing:
            parts.append("missing " + ", ".join(missing))
        if extra:
            parts.append("unknown " + ", ".join(extra))
        _fail(path, "; ".join(parts))


def _string(value, path, *, pattern=None):
    if not isinstance(value, str) or not value:
        _fail(path, "must be a non-empty string")
    if pattern is not None and not pattern.fullmatch(value):
        _fail(path, "has invalid format")
    return value


def _bool(value, path):
    if not isinstance(value, bool):
        _fail(path, "must be a boolean")
    return value


def _integer(value, path, *, minimum=None):
    if isinstance(value, bool) or not isinstance(value, int):
        _fail(path, "must be an integer")
    if minimum is not None and value < minimum:
        _fail(path, "must be at least %d" % minimum)
    return value


def _number(value, path):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        _fail(path, "must be a number")
    return value


def _nullable_positive_integer(value, path):
    if value is None:
        return None
    return _integer(value, path, minimum=1)


def _sha256_text(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def validate_contract(record, *, exact=True):
    _exact_keys(record, TOP_KEYS, "$")
    if record["schemaVersion"] != 1:
        _fail("$.schemaVersion", "must equal 1")
    if record["platform"] not in PLATFORMS:
        _fail("$.platform", "must be ios or android")
    _string(record["sourceSha"], "$.sourceSha", pattern=SHA1_RE)
    _string(record["modelSha256"], "$.modelSha256", pattern=SHA256_RE)
    _string(record["caseId"], "$.caseId", pattern=CASE_ID_RE)
    if record["requestKind"] not in REQUEST_KINDS:
        _fail("$.requestKind", "unknown task")

    request = _object(record["request"], "$.request")
    _exact_keys(request, REQUEST_KEYS, "$.request")
    _object(request["controls"], "$.request.controls")
    _object(request["localContext"], "$.request.localContext")

    prompt = _object(record["prompt"], "$.prompt")
    _exact_keys(prompt, PROMPT_KEYS, "$.prompt")
    user_text = _string(prompt["userText"], "$.prompt.userText")
    rendered_text = _string(prompt["renderedText"], "$.prompt.renderedText")
    user_hash = _string(prompt["userTextSha256"], "$.prompt.userTextSha256", pattern=SHA256_RE)
    rendered_hash = _string(
        prompt["renderedTextSha256"], "$.prompt.renderedTextSha256", pattern=SHA256_RE
    )
    if user_hash != _sha256_text(user_text):
        _fail("$.prompt.userTextSha256", "does not match userText UTF-8 bytes")
    if rendered_hash != _sha256_text(rendered_text):
        _fail("$.prompt.renderedTextSha256", "does not match renderedText UTF-8 bytes")
    _string(prompt["tokenizerArchitecture"], "$.prompt.tokenizerArchitecture")
    _string(prompt["tokenizerEnvelope"], "$.prompt.tokenizerEnvelope")
    template_hash = _string(
        prompt["tokenizerChatTemplateSha256"],
        "$.prompt.tokenizerChatTemplateSha256",
        pattern=SHA256_RE,
    )
    tokenization = _object(prompt["tokenization"], "$.prompt.tokenization")
    _exact_keys(tokenization, TOKENIZATION_KEYS, "$.prompt.tokenization")
    _bool(tokenization["addSpecial"], "$.prompt.tokenization.addSpecial")
    _bool(tokenization["parseSpecial"], "$.prompt.tokenization.parseSpecial")

    generation = _object(record["generation"], "$.generation")
    _exact_keys(generation, GENERATION_KEYS, "$.generation")
    engine = _object(generation["engine"], "$.generation.engine")
    _exact_keys(engine, ENGINE_KEYS, "$.generation.engine")
    _string(engine["name"], "$.generation.engine.name")
    _string(engine["version"], "$.generation.engine.version")
    _integer(generation["contextLength"], "$.generation.contextLength", minimum=1)

    sampler = _object(generation["sampler"], "$.generation.sampler")
    _exact_keys(sampler, SAMPLER_KEYS, "$.generation.sampler")
    seed = _object(sampler["seed"], "$.generation.sampler.seed")
    _exact_keys(seed, SEED_KEYS, "$.generation.sampler.seed")
    if seed["policy"] not in {"fixed", "randomPerRequest", "engineDefault"}:
        _fail("$.generation.sampler.seed.policy", "unknown seed policy")
    if seed["value"] is not None:
        _integer(seed["value"], "$.generation.sampler.seed.value")
    chain = sampler["chain"]
    if not isinstance(chain, list) or not chain:
        _fail("$.generation.sampler.chain", "must be a non-empty array")
    for index, stage in enumerate(chain):
        path = "$.generation.sampler.chain[%d]" % index
        _exact_keys(stage, SAMPLER_STAGE_KEYS, path)
        algorithm = _string(stage["algorithm"], path + ".algorithm")
        if algorithm not in SAMPLER_PARAMETERS:
            _fail(path + ".algorithm", "unsupported exact-replay sampler %r" % algorithm)
        parameters = _object(stage["parameters"], path + ".parameters")
        _exact_keys(parameters, SAMPLER_PARAMETERS[algorithm], path + ".parameters")
        for name, value in parameters.items():
            if name in {"lastN", "minimumKeep"}:
                _integer(value, path + ".parameters." + name, minimum=0)
            elif name == "penalizeNewline":
                _bool(value, path + ".parameters." + name)
            else:
                _number(value, path + ".parameters." + name)

    termination = _object(generation["termination"], "$.generation.termination")
    _exact_keys(termination, TERMINATION_KEYS, "$.generation.termination")
    _bool(termination["stopOnEog"], "$.generation.termination.stopOnEog")
    stops = termination["stopSequences"]
    if not isinstance(stops, list) or any(not isinstance(item, str) or not item for item in stops):
        _fail("$.generation.termination.stopSequences", "must contain non-empty strings")
    if len(stops) != len(set(stops)):
        _fail("$.generation.termination.stopSequences", "must not contain duplicates")
    _nullable_positive_integer(
        termination["maximumOutputTokens"],
        "$.generation.termination.maximumOutputTokens",
    )
    _nullable_positive_integer(
        termination["maximumResponseLength"],
        "$.generation.termination.maximumResponseLength",
    )
    if termination["responseLengthUnit"] not in {"utf8Bytes", "utf16CodeUnits"}:
        _fail("$.generation.termination.responseLengthUnit", "unknown response length unit")
    _nullable_positive_integer(termination["deadlineMs"], "$.generation.termination.deadlineMs")
    if termination["reason"] not in TERMINATION_REASONS:
        _fail("$.generation.termination.reason", "unknown termination reason")

    cache = _object(generation["cache"], "$.generation.cache")
    _exact_keys(cache, CACHE_KEYS, "$.generation.cache")
    _bool(cache["clearKvBeforeRequest"], "$.generation.cache.clearKvBeforeRequest")
    _bool(cache["promptCache"], "$.generation.cache.promptCache")
    if cache["state"] not in {"cold", "warm"}:
        _fail("$.generation.cache.state", "must be cold or warm")

    runtime = _object(record["runtime"], "$.runtime")
    _exact_keys(runtime, RUNTIME_KEYS, "$.runtime")
    for key in ("target", "osVersion", "buildVariant"):
        _string(runtime[key], "$.runtime." + key)
    if runtime["evidenceKind"] not in {"nativeRun", "controlledReplay", "contractExport"}:
        _fail("$.runtime.evidenceKind", "unknown evidence kind")
    evidence_kind = runtime["evidenceKind"]
    captured_at = _string(runtime["capturedAt"], "$.runtime.capturedAt")
    try:
        dt.datetime.fromisoformat(captured_at.replace("Z", "+00:00"))
    except ValueError:
        _fail("$.runtime.capturedAt", "must be ISO-8601")

    missing_random_export_seed = (
        evidence_kind == "contractExport"
        and seed["policy"] == "randomPerRequest"
        and seed["value"] is None
    )
    if exact and seed["value"] is None and not missing_random_export_seed:
        _fail(
            "$.generation.sampler.seed.value",
            "%s requires the actual native seed" % evidence_kind,
        )

    if exact:
        if record["caseId"].startswith("schema_example_"):
            _fail("$.caseId", "illustrative schema examples cannot be replayed")
        if template_hash == "0" * 64:
            _fail("$.prompt.tokenizerChatTemplateSha256", "placeholder hash is not exact provenance")
        if engine["version"] == "producer-reported":
            _fail("$.generation.engine.version", "placeholder version is not exact provenance")
    return record


def load_contracts(paths, *, exact=True):
    records = []
    for path in paths:
        with open(path, "r", encoding="utf-8") as handle:
            if str(path).endswith(".jsonl"):
                values = [json.loads(line) for line in handle if line.strip()]
            else:
                payload = json.load(handle)
                values = payload if isinstance(payload, list) else [payload]
        for index, record in enumerate(values):
            try:
                records.append(validate_contract(record, exact=exact))
            except ContractError as error:
                raise ContractError("%s[%d]: %s" % (path, index, error)) from error
    if not records:
        raise ContractError("no native contract records found")
    identities = [(record["platform"], record["caseId"]) for record in records]
    if len(identities) != len(set(identities)):
        raise ContractError("duplicate platform/caseId native contract")
    return records


def load_case_manifest(path):
    with open(path, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    if manifest.get("manifestVersion") != 1:
        raise ContractError("case manifest version must equal 1")
    cases = manifest.get("cases")
    if not isinstance(cases, list) or not cases:
        raise ContractError("case manifest must contain cases")
    case_ids = [row.get("caseId") for row in cases]
    if any(not isinstance(case_id, str) for case_id in case_ids):
        raise ContractError("case manifest has an invalid caseId")
    if len(case_ids) != len(set(case_ids)):
        raise ContractError("case manifest contains duplicate caseIds")
    return manifest


def validate_manifest_records(records, manifest):
    cases = {row["caseId"]: row for row in manifest["cases"]}
    expected_ids = set(cases)
    for platform in PLATFORMS:
        platform_ids = {
            record["caseId"] for record in records if record["platform"] == platform
        }
        if platform_ids and platform_ids != expected_ids:
            missing = sorted(expected_ids - platform_ids)
            extra = sorted(platform_ids - expected_ids)
            raise ContractError(
                "%s export differs from case manifest (missing=%s extra=%s)"
                % (platform, missing, extra)
            )
    capture = manifest["captureByPlatform"]
    for record in records:
        case = cases.get(record["caseId"])
        if case is None:
            raise ContractError("%s: caseId is not in the frozen manifest" % record["caseId"])
        for key in ("requestKind", "request"):
            if record[key] != case[key]:
                raise ContractError(
                    "%s/%s: export differs from manifest %s"
                    % (record["platform"], record["caseId"], key)
                )
        if record["modelSha256"] != manifest["modelSha256"]:
            raise ContractError("%s: model SHA differs from manifest" % record["caseId"])
        expected_capture = capture[record["platform"]]
        if record["runtime"]["evidenceKind"] != expected_capture["evidenceKind"]:
            raise ContractError("%s: evidenceKind differs from manifest" % record["caseId"])
        expected_seed = expected_capture["seed"]
        actual_seed = record["generation"]["sampler"]["seed"]
        if actual_seed["policy"] != expected_seed["policy"]:
            raise ContractError("%s: seed policy differs from manifest" % record["caseId"])
        if actual_seed["value"] != expected_seed["value"]:
            raise ContractError("%s: seed value differs from manifest" % record["caseId"])
    return records


def validate_platform_pairs(records):
    platforms = {record["platform"] for record in records}
    if platforms != PLATFORMS:
        raise ContractError("exact evaluation requires both ios and android exports")
    by_platform = {
        platform: {record["caseId"]: record for record in records if record["platform"] == platform}
        for platform in PLATFORMS
    }
    if set(by_platform["ios"]) != set(by_platform["android"]):
        raise ContractError("ios and android exports must contain the same caseId set")
    for case_id in sorted(by_platform["ios"]):
        ios = by_platform["ios"][case_id]
        android = by_platform["android"][case_id]
        for key in ("modelSha256", "requestKind", "request"):
            if ios[key] != android[key]:
                raise ContractError("%s: native exports disagree on %s" % (case_id, key))
    return records


def model_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def response_length(text, unit):
    if unit == "utf8Bytes":
        return len(text.encode("utf-8"))
    if unit == "utf16CodeUnits":
        return len(text.encode("utf-16-le")) // 2
    raise ContractError("unknown response length unit %r" % unit)


def response_prefix(text, limit, unit):
    if limit <= 0:
        return ""
    end = 0
    for index in range(1, len(text) + 1):
        if response_length(text[:index], unit) > limit:
            break
        end = index
    return text[:end]


def validate_replay_seed(value):
    return _integer(value, "--replay-seed", minimum=0)


def scoring_case(record):
    controls = record["request"]["controls"]
    context = record["request"]["localContext"]
    task = record["requestKind"]
    case = {"id": record["caseId"], "task": task}

    def required(source, names, path):
        missing = [name for name in names if name not in source]
        if missing:
            _fail(path, "missing " + ", ".join(missing))

    if task == "suggestions":
        required(controls, ("targetRhymeLine", "rhymeType"), "$.request.controls")
        required(context, ("lyrics",), "$.request.localContext")
        case.update({
            "lyrics": context["lyrics"],
            "target_rhyme_line": controls["targetRhymeLine"],
            "rhyme_type": controls["rhymeType"],
        })
    elif task == "rewrite_passage":
        required(context, ("selection",), "$.request.localContext")
        case["selection"] = context["selection"]
    elif task == "rewrite_word":
        required(controls, ("action", "rejectedCandidates"), "$.request.controls")
        required(context, ("selection",), "$.request.localContext")
        case.update({
            "action": controls["action"],
            "selection": context["selection"],
            "rejected": controls["rejectedCandidates"],
        })
    elif task == "synonyms":
        required(controls, ("limit",), "$.request.controls")
        required(context, ("word",), "$.request.localContext")
        case.update({"limit": controls["limit"], "word": context["word"]})
    return case


def completion_body(record, *, replay_seed):
    generation = record["generation"]
    sampler = generation["sampler"]
    termination = generation["termination"]
    validate_replay_seed(replay_seed)
    body = {
        "prompt": record["prompt"]["renderedText"],
        "n_predict": termination["maximumOutputTokens"]
        if termination["maximumOutputTokens"] is not None else -1,
        "seed": replay_seed,
        "stop": termination["stopSequences"],
        "cache_prompt": generation["cache"]["promptCache"],
    }
    order = []
    minimum_keeps = set()
    for stage in sampler["chain"]:
        algorithm = stage["algorithm"]
        params = stage["parameters"]
        if algorithm == "penalties":
            order.append("penalties")
            body.update({
                "repeat_last_n": params["lastN"],
                "repeat_penalty": params["repeat"],
                "frequency_penalty": params["frequency"],
                "presence_penalty": params["presence"],
                "penalize_nl": params["penalizeNewline"],
            })
        elif algorithm == "topK":
            order.append("top_k")
            body["top_k"] = params["k"]
        elif algorithm == "topP":
            order.append("top_p")
            body["top_p"] = params["p"]
            minimum_keeps.add(params["minimumKeep"])
        elif algorithm == "minP":
            order.append("min_p")
            body["min_p"] = params["p"]
            minimum_keeps.add(params["minimumKeep"])
        elif algorithm == "typicalP":
            order.append("typ_p")
            body["typical_p"] = params["p"]
            minimum_keeps.add(params["minimumKeep"])
        elif algorithm == "tailFree":
            order.append("tfs_z")
            body["tfs_z"] = params["z"]
            minimum_keeps.add(params["minimumKeep"])
        elif algorithm == "xtc":
            order.append("xtc")
            body["xtc_probability"] = params["probability"]
            body["xtc_threshold"] = params["threshold"]
            minimum_keeps.add(params["minimumKeep"])
        elif algorithm == "temperature":
            order.append("temperature")
            body["temperature"] = params["value"]
        elif algorithm == "distribution":
            continue
    if len(minimum_keeps) > 1:
        raise ContractError(
            "llama-server exposes one min_keep value; native sampler stages disagree: %s"
            % sorted(minimum_keeps)
        )
    if minimum_keeps:
        body["min_keep"] = minimum_keeps.pop()
    body["samplers"] = order
    body["ignore_eos"] = not termination["stopOnEog"]
    return body


def main():
    parser = argparse.ArgumentParser(description="Validate native model-contract exports")
    parser.add_argument("--manifest", required=True, help="Frozen shared case manifest")
    parser.add_argument("--require-pairs", action="store_true")
    parser.add_argument("contracts", nargs="+")
    args = parser.parse_args()

    manifest = load_case_manifest(args.manifest)
    records = load_contracts(args.contracts, exact=True)
    validate_manifest_records(records, manifest)
    if args.require_pairs:
        validate_platform_pairs(records)
    platforms = {
        platform: sum(1 for record in records if record["platform"] == platform)
        for platform in sorted(PLATFORMS)
    }
    print(json.dumps({
        "valid": True,
        "recordCount": len(records),
        "platformCounts": platforms,
        "manifestSha256": model_sha256(args.manifest),
    }, sort_keys=True))


if __name__ == "__main__":
    main()
