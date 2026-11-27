import 'package:checked_json/checked_json.dart' show JsonObject;

/// Throws a [FormatException] naming [what] and the first key of [json]
/// not in [fields].
void onlyFields(JsonObject json, Set<String> fields, String what) {
  for (final key in json.keys) {
    if (!fields.contains(key)) {
      throw FormatException('`$key` is not a field of $what');
    }
  }
}
