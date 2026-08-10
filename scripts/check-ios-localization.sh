#!/usr/bin/env bash
set -euo pipefail

# Reject new visible Chinese literals in Swift. Protocol/error matching is explicitly
# documented in the allowlist because changing those values would break compatibility.
python3 - <<'PY'
from pathlib import Path
import json
import plistlib
import re
import sys

root = Path("ios/MimiRemote")
catalog_path = root / "Resources/Localizable.xcstrings"
allowlist_path = root / "Resources/LocalizationTechnicalStringAllowlist.json"

catalog = json.loads(catalog_path.read_text())
strings = catalog.get("strings", {})
errors = []

if catalog.get("version") not in ("1.0", "1.1"):
    errors.append('String Catalog must declare a supported version ("1.0" or "1.1")')

permission_keys = (
    "NSLocalNetworkUsageDescription",
    "NSCameraUsageDescription",
    "NSMicrophoneUsageDescription",
    "NSSpeechRecognitionUsageDescription",
)
cjk_pattern = re.compile(r"[\u3400-\u9fff]")
for plist_name in ("Info.plist", "Info-Catalyst.plist"):
    plist_path = root / "Resources" / plist_name
    try:
        plist = plistlib.loads(plist_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        errors.append(f"Could not read {plist_name}: {error}")
        continue
    for key in permission_keys:
        value = plist.get(key)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{plist_name} is missing {key}")
        elif cjk_pattern.search(value):
            errors.append(f"{plist_name} {key} must be an English fallback")

for language in ("en", "zh-Hans"):
    strings_path = root / "Resources" / f"{language}.lproj" / "InfoPlist.strings"
    if not strings_path.is_file():
        errors.append(f"Missing InfoPlist localization: {strings_path}")
        continue
    strings_text = strings_path.read_text()
    for key in permission_keys:
        match = re.search(rf'"{re.escape(key)}"\s*=\s*"((?:\\.|[^"\\])*)"\s*;', strings_text)
        if not match:
            errors.append(f"{strings_path} is missing {key}")
            continue
        value = match.group(1)
        if language == "en" and cjk_pattern.search(value):
            errors.append(f"English InfoPlist localization contains Chinese text: {key}")
        if language == "zh-Hans" and not cjk_pattern.search(value):
            errors.append(f"Simplified Chinese InfoPlist localization lacks Chinese text: {key}")

project_yml = (root / "project.yml").read_text()
for language in ("en", "zh-Hans"):
    expected_path = f"Resources/{language}.lproj/InfoPlist.strings"
    if expected_path not in project_yml:
        errors.append(f"project.yml does not include {expected_path} as a resource")

# Localization regressions must be visible to pull requests, not only runnable by hand.
# Keep the core suite on its established Chinese baseline and exercise the dedicated
# catalog smoke independently in English on fresh GitHub runners.
workflow_path = Path(".github/workflows/ios-ci.yml")
if not workflow_path.is_file():
    errors.append("Missing iOS CI workflow")
else:
    workflow = workflow_path.read_text()
    for required in (
        '"scripts/check-ios-localization.sh"',
        "run: bash ./scripts/check-ios-localization.sh",
        '"scripts/test-ios-localization-smoke.sh"',
        "run: bash ./scripts/test-ios-localization-smoke.sh",
        "inputs.publish_internal_testflight ||",
        "github.event_name == 'workflow_dispatch' && inputs.publish_app_store",
    ):
        if required not in workflow:
            errors.append(f"iOS CI workflow is missing localization coverage: {required}")

for script_name, required in (
    ("scripts/test-conversation-regressions.sh", ("-testLanguage zh-Hans", "-testRegion CN")),
    ("scripts/test-ios-localization-smoke.sh", ("-testLanguage en", "-testRegion US")),
):
    script_path = Path(script_name)
    if not script_path.is_file():
        errors.append(f"Missing localization test script: {script_name}")
        continue
    script = script_path.read_text()
    for flag in required:
        if flag not in script:
            errors.append(f"{script_name} must set {flag}")

core_runner = Path("scripts/test-conversation-regressions.sh").read_text()
if "-only-testing:MimiRemoteTests/LocalizationTests" not in core_runner:
    errors.append("Core iOS regression must include LocalizationTests")

def localized_values(entry, language):
    localization = entry.get("localizations", {}).get(language)
    if localization is None:
        return []
    if "stringUnit" in localization:
        return [localization["stringUnit"].get("value", "")]
    return [
        variant.get("stringUnit", {}).get("value", "")
        for variant in localization.get("variations", {}).get("plural", {}).values()
    ]

translatable_strings = {
    key: entry
    for key, entry in strings.items()
    if entry.get("shouldTranslate", True)
}

for language in ("en", "zh-Hans"):
    if not all(language in entry.get("localizations", {}) for entry in translatable_strings.values()):
        errors.append(f"String Catalog has an entry without {language} translation")

for key, entry in translatable_strings.items():
    for value in localized_values(entry, "en"):
        if re.search(r"[\u3400-\u9fff]", value):
            errors.append(f"English catalog value contains Chinese text: {key}")

# Product terms with protocol significance must remain stable in English. `turn/steer`
# is the underlying operation, so the Composer must not drift back to Guide, Lead, or
# Direct for the same user-facing action. Keep connection-routing "direct" strings out
# of this narrow list because they describe a different feature.
steering_keys = (
    "ui.boot_input_skipped",
    "ui.boot_input_submitted",
    "ui.boot_value",
    "ui.confirm_boot",
    "ui.conversation_guided",
    "ui.direct_current_reply_now",
    "ui.directed_current_reply_immediately",
    "ui.failed_to_guide_conversation_there_is_no_active",
    "ui.guide",
    "ui.guide_current_reply_no_active_round_currently",
    "ui.guide_is_being_sent",
    "ui.immediately_change_the_reply_currently_being_generated",
    "ui.lead_current_reply",
    "ui.tap_to_toggle_queuing_or_directing_current_replies",
    "ui.there_are_currently_no_active_rounds_to_boot",
    "ui.waiting_for_boot_input",
)
steering_drift = re.compile(r"\b(?:guide|guidance|guided|lead|direct(?:ed|ing)?)\b", re.IGNORECASE)
for key in steering_keys:
    for value in localized_values(strings[key], "en"):
        if steering_drift.search(value):
            errors.append(f"Steering UI must use Steer terminology: {key}")

for key, entry in translatable_strings.items():
    for value in localized_values(entry, "en"):
        if re.search(r"\bassistant\b", value, re.IGNORECASE) and "Mimi Mac Assistant" not in value:
            errors.append(f"Mac component name must be Mimi Mac Assistant: {key}")

for key in (
    "ui.ipad_to_agentd_healthz",
    "ui.prioritize_checking_ipads_and_tailscale_networks",
    "ui.write_back_to_ipad",
):
    if "ipad" in strings[key]["localizations"]["en"]["stringUnit"]["value"].lower():
        errors.append(f"Cross-device diagnostic must not be iPad-specific: {key}")

allowlist = {item["value"] for item in json.loads(allowlist_path.read_text()).get("items", [])}
ui_literal_allowlist = {
    item["value"]
    for item in json.loads(allowlist_path.read_text()).get("uiLiteralAllowlist", [])
}
used_keys = set()
key_usage = {}
format_calls = []
literal_pattern = re.compile(r'(?<!\\)"((?:\\.|[^"\\])*)"')
# Full-width punctuation is user-visible too. Keeping it here prevents an English
# screen from inheriting Chinese separators from Swift interpolation glue.
visible_ui_pattern = re.compile(r"[\u3400-\u9fff\uff01\uff08\uff09\uff0c\uff1a\uff1b\uff1f\u3002]")
direct_ui_literal_pattern = re.compile(
    r'(?:\b(?:Text|Label|Button|TextField|SecureField|Toggle|Picker|Section|Menu|ContentUnavailableView)\s*\('
    r'|\.(?:navigationTitle|accessibilityLabel|accessibilityHint|accessibilityValue|alert|confirmationDialog|help)\s*\()'
    r'\s*"((?:\\.|[^"\\])*)"'
)

def swift_function_calls(source_text, function_name):
    """Return (argument text, offset) for balanced Swift calls with static keys."""
    cursor = 0
    while True:
        start = source_text.find(function_name, cursor)
        if start == -1:
            return
        open_paren = start + len(function_name)
        while open_paren < len(source_text) and source_text[open_paren].isspace():
            open_paren += 1
        if open_paren >= len(source_text) or source_text[open_paren] != "(":
            cursor = start + len(function_name)
            continue

        depth = 1
        index = open_paren + 1
        in_string = False
        escaped = False
        while index < len(source_text) and depth:
            char = source_text[index]
            if in_string:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    in_string = False
            elif char == '"':
                in_string = True
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
            index += 1
        if depth:
            errors.append(f"Unbalanced {function_name} call: offset {start}")
            return
        yield source_text[open_paren + 1:index - 1], start
        cursor = index

def split_swift_arguments(text):
    arguments = []
    start = 0
    depth = 0
    in_string = False
    escaped = False
    for index, char in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            arguments.append(text[start:index].strip())
            start = index + 1
    tail = text[start:].strip()
    if tail:
        arguments.append(tail)
    return arguments

format_specifier = re.compile(
    r"%(?:(?P<position>\d+)\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?:hh|h|ll|l|q|L|z|t|j)?(?P<conversion>[@diuoxXfFeEgGaAcCsSp])"
)

def format_argument_count(value):
    """Return Foundation format argument count, supporting %@ and positional forms."""
    index = 0
    unpositioned = 0
    positions = set()
    while index < len(value):
        if value[index] != "%":
            index += 1
            continue
        if index + 1 < len(value) and value[index + 1] == "%":
            index += 2
            continue
        match = format_specifier.match(value, index)
        if not match:
            raise ValueError(f"unsupported format placeholder near {value[index:index + 12]!r}")
        if "*" in match.group(0):
            raise ValueError("dynamic width or precision is not supported in UI strings")
        position = match.group("position")
        if position:
            positions.add(int(position))
        else:
            unpositioned += 1
        index = match.end()
    if positions and unpositioned:
        raise ValueError("cannot mix positional and unpositioned placeholders")
    return max(positions) if positions else unpositioned

def format_conversions(value):
    """Return Foundation conversion characters, excluding escaped percent signs."""
    conversions = []
    index = 0
    while index < len(value):
        if value[index] != "%":
            index += 1
            continue
        if index + 1 < len(value) and value[index + 1] == "%":
            index += 2
            continue
        match = format_specifier.match(value, index)
        if not match:
            raise ValueError(f"unsupported format placeholder near {value[index:index + 12]!r}")
        conversions.append(match.group("conversion"))
        index = match.end()
    return conversions

for source in (root / "Sources").rglob("*.swift"):
    source_text = source.read_text()
    for method, key in re.findall(r'L10n\.(text|plural)\(\s*"([^"]+)"', source_text):
        used_keys.add(key)
        key_usage.setdefault(key, set()).add(method)
    for call, offset in swift_function_calls(source_text, "L10n.format"):
        arguments = split_swift_arguments(call)
        key_match = re.fullmatch(r'"([^"]+)"', arguments[0]) if arguments else None
        if not key_match:
            line_number = source_text.count("\n", 0, offset) + 1
            errors.append(f"L10n.format needs a static catalog key: {source}:{line_number}")
            continue
        key = key_match.group(1)
        used_keys.add(key)
        key_usage.setdefault(key, set()).add("format")
        format_calls.append((key, max(0, len(arguments) - 1), source, source_text.count("\n", 0, offset) + 1))
    for line_number, line in enumerate(source_text.splitlines(), 1):
        if re.match(r"^\s*//", line):
            continue
        for literal in literal_pattern.findall(line):
            if not visible_ui_pattern.search(literal):
                continue
            if literal not in allowlist:
                errors.append(f"Unlocalized Swift literal: {source}:{line_number}: {literal}")

    # These constructors make their first String argument visible to the user.
    # Dynamic-only values (for example "\\(session.title)") originate from
    # already-localized runtime data, but any authored prefix must use L10n.
    for match in direct_ui_literal_pattern.finditer(source_text):
        literal = match.group(1)
        if not literal or re.match(r"^(?:[@$])?\\\(", literal):
            continue
        if literal not in ui_literal_allowlist:
            line_number = source_text.count("\n", 0, match.start()) + 1
            errors.append(
                f"Unlocalized direct UI literal: {source}:{line_number}: {literal}. "
                "Use L10n or document a technical exception."
            )

for key in sorted(used_keys - strings.keys()):
    errors.append(f"Swift references a missing String Catalog key: {key}")

# A bare text lookup must never resolve to an interpolation template. Each format
# call must provide exactly the number of Foundation arguments required by every
# language. This prevents silently dropping a value when a catalog entry loses a
# placeholder, including when translators use positional placeholders such as %2$@.
for key, methods in sorted(key_usage.items()):
    if key not in strings:
        continue
    values = {
        language: localized_values(strings[key], language)
        for language in ("en", "zh-Hans")
    }
    for language, entries in values.items():
        for value in entries:
            try:
                count = format_argument_count(value)
                conversions = format_conversions(value)
            except ValueError as error:
                errors.append(f"Invalid Foundation format in {language} for {key}: {error}")
                continue
            if "text" in methods and count:
                errors.append(f"L10n.text uses an interpolation template: {key}")
            if "plural" in methods and count != 1:
                errors.append(f"L10n.plural must use exactly one numeric placeholder: {key}")
            if "plural" in methods and (len(conversions) != 1 or conversions[0] != "d" or "%lld" not in value):
                errors.append(f"L10n.plural must use one %lld placeholder: {language} {key}")

for key, supplied_count, source, line_number in format_calls:
    if key not in strings:
        continue
    for language in ("en", "zh-Hans"):
        for value in localized_values(strings[key], language):
            try:
                expected_count = format_argument_count(value)
                conversions = format_conversions(value)
            except ValueError as error:
                errors.append(f"Invalid Foundation format in {language} for {key}: {error}")
                continue
            if any(conversion != "@" for conversion in conversions):
                errors.append(
                    f"L10n.format only supports %@ object placeholders: {language} {key}"
                )
            if supplied_count != expected_count:
                errors.append(
                    f"L10n.format argument mismatch at {source}:{line_number}: {key} "
                    f"supplies {supplied_count}, but {language} requires {expected_count}"
                )

# `L10n.format` is intentionally object-only. A number rendered through `%@` next
# to a countable English noun almost always loses the singular form ("1 files").
# Keep the narrow list focused on common product counts; use `L10n.plural` instead.
format_plural_noun_pattern = re.compile(
    r"%(?:\d+\$)?@\s+(?:(?:missing|more|additional|remaining|installed|available|matching|"
    r"optional|review|upstream\s+dial|modified|staged)\s+)?"
    r"(?:sessions?|files?|workspaces?|worktrees?|items?|matches|plugins?|skills?|models?|"
    r"requests?|days?|seconds?|minutes?|hours?|activities|suggestions?|comments?|results?|times?)\b",
    re.IGNORECASE,
)
for key, methods in sorted(key_usage.items()):
    if key not in strings or "format" not in methods:
        continue
    for value in localized_values(strings[key], "en"):
        if format_plural_noun_pattern.search(value):
            errors.append(
                f"L10n.format countable English template must use L10n.plural: {key}"
            )

if errors:
    print("iOS localization check failed:", file=sys.stderr)
    print("\n".join(f"- {error}" for error in errors), file=sys.stderr)
    sys.exit(1)

print(f"iOS localization static check passed ({len(used_keys)} keys, {len(allowlist)} technical exceptions).")
PY

# The JSON shape is not sufficient: xcstringstool catches String Catalog schema
# errors that Xcode would otherwise report only during a later build.
catalog_output_directory="$(mktemp -d)"
trap 'rm -rf "$catalog_output_directory"' EXIT
xcrun xcstringstool compile \
  ios/MimiRemote/Resources/Localizable.xcstrings \
  --output-directory "$catalog_output_directory" \
  --language en \
  --language zh-Hans >/dev/null

echo "iOS String Catalog compile passed."
