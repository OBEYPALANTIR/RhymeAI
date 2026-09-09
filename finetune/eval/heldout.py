"""Held-out lexical, inflection, POS, and contextual-substitution scoring."""

from __future__ import annotations

import json

from . import scoring


def load(path):
    with open(path, "r", encoding="utf-8") as handle:
        rows = json.load(handle)
    if not isinstance(rows, list) or not rows:
        raise ValueError("held-out fixture must be a non-empty JSON array")
    by_id = {}
    for row in rows:
        case_id = row["caseId"]
        if case_id in by_id:
            raise ValueError("duplicate held-out caseId %s" % case_id)
        by_id[case_id] = row
    return by_id


def validate_contract(fixture, contract):
    if fixture["requestKind"] != contract["requestKind"]:
        raise ValueError("%s: requestKind differs from held-out fixture" % fixture["caseId"])
    if fixture["request"] != contract["request"]:
        raise ValueError("%s: native request differs from held-out fixture" % fixture["caseId"])


def score_candidates(candidates, fixture):
    evaluation = fixture["evaluation"]
    accepted = {scoring.lexical_spelling(word) for word in evaluation["acceptedSpellings"]}
    rejected = {scoring.rejection_key(word) for word in evaluation["rejectedSpellings"]}
    per_candidate = []
    for candidate in candidates:
        spelling = scoring.lexical_spelling(candidate)
        lexical_valid = scoring.is_lexically_valid(candidate)
        rejected_candidate = scoring.rejection_key(candidate) in rejected
        contextual_fit = spelling in accepted
        per_candidate.append({
            "candidate": candidate,
            "lexical_spelling": spelling,
            "lexically_valid": lexical_valid,
            "rejected_candidate": rejected_candidate,
            "expected_part_of_speech": evaluation["expectedPartOfSpeech"],
            "fixture_contextual_fit": contextual_fit,
        })
    return {
        "lexical_validity_passed": bool(per_candidate)
        and all(item["lexically_valid"] for item in per_candidate),
        "rejection_passed": all(not item["rejected_candidate"] for item in per_candidate),
        "fixture_pos_and_context_passed": bool(per_candidate)
        and all(item["fixture_contextual_fit"] for item in per_candidate),
        "human_semantic_rating": (
            "unverified" if evaluation["requiresHumanSemanticRating"] else "notRequired"
        ),
        "candidates": per_candidate,
    }


def candidates_from_score(task, score):
    if task == "rewrite_word":
        word = score["format"]["word"]
        return [word] if word else []
    if task == "synonyms":
        return score["format"]["words"]
    return []


def adversarial_violations(fixture, output):
    task = fixture["requestKind"]
    request = fixture["request"]
    if task == "rewrite_word":
        result = scoring.validate_single_word_rewrite(
            output,
            request["localContext"]["selection"],
            request["controls"]["rejectedCandidates"],
        )
        candidate_score = score_candidates([result["word"]] if result["word"] else [], fixture)
        contextual_mismatch = any(
            not item["fixture_contextual_fit"] for item in candidate_score["candidates"]
        )
        return {
            "invalidLexicalSpelling": "invalid_lexical_spelling" in result["violations"],
            "rejectedCandidate": "in_rejected_list" in result["violations"],
            "partOfSpeechMismatch": contextual_mismatch,
            "inflectionMismatch": contextual_mismatch,
            "contextualMismatch": contextual_mismatch,
        }
    if task == "synonyms":
        result = scoring.validate_synonyms(
            output,
            request["localContext"]["word"],
            request["controls"]["limit"],
        )
        flattened = {
            violation
            for _, violations in result["violations"]
            for violation in violations
        }
        candidate_score = score_candidates(result["words"], fixture)
        contextual_mismatch = any(
            not item["fixture_contextual_fit"] for item in candidate_score["candidates"]
        )
        return {
            "invalidLexicalSpelling": "invalid_lexical_spelling" in flattened,
            "rejectedCandidate": any(
                item["rejected_candidate"] for item in candidate_score["candidates"]
            ),
            "partOfSpeechMismatch": contextual_mismatch,
            "inflectionMismatch": contextual_mismatch,
            "contextualMismatch": contextual_mismatch,
        }
    raise ValueError("adversarial scoring only supports word tasks")
