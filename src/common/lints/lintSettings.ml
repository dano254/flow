(**
 * Copyright (c) 2013-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "flow" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

type lint_kind =
  | SketchyNullBool
  | SketchyNullString
  | SketchyNullNumber
  | SketchyNullMixed

let string_of_kind = function
  | SketchyNullBool -> "sketchy-null-bool"
  | SketchyNullString -> "sketchy-null-string"
  | SketchyNullNumber -> "sketchy-null-number"
  | SketchyNullMixed -> "sketchy-null-mixed"

let kinds_of_string = function
  | "sketchy-null" -> [SketchyNullBool; SketchyNullString; SketchyNullNumber; SketchyNullMixed]
  | "sketchy-null-bool" -> [SketchyNullBool]
  | "sketchy-null-string" -> [SketchyNullString]
  | "sketchy-null-number" -> [SketchyNullNumber]
  | "sketchy-null-mixed" -> [SketchyNullMixed]
  | _ -> raise Not_found

module LintKind = struct
  type t = lint_kind
  let compare = compare
end

module LintMap = MyMap.Make(LintKind)

type t = {
  (* Whether to throw an error if the error kind isn't found in the map *)
  default_err: bool;
  (* Whether default_err has been explicitly set by an "all=..." command
   * (used in merge) *)
  all_encountered: bool;
  (* Settings for lints that have been explicitly mentioned *)
  (* The Loc.t is for settings defined in comments, and is used to find unused lint
   * suppressions. The Loc.t is set to None for settings coming from the flowconfig or --lints.*)
  explicit_settings: (bool * Loc.t option) LintMap.t;
}

let default_settings = {
  default_err = false;
  all_encountered = false;
  explicit_settings = LintMap.empty
}

let all_setting default_err = {
  default_err;
  all_encountered = true;
  explicit_settings = LintMap.empty
}

let set_enabled key value settings =
  let new_map = LintMap.add key value settings.explicit_settings
  in {settings with explicit_settings = new_map}

let set_all entries settings =
  List.fold_left (fun settings (key, value) -> set_enabled key value settings) settings entries

let get_default settings = settings.default_err

let is_enabled lint_kind settings =
  LintMap.get lint_kind settings.explicit_settings
  |> Option.value_map ~f:fst ~default:settings.default_err

let is_suppressed lint_kind settings =
  is_enabled lint_kind settings |> not

let get_loc lint_kind settings =
  LintMap.get lint_kind settings.explicit_settings
  |> Option.value_map ~f:snd ~default:None

(* Iterate over all lint kinds with an explicit setting *)
let iter f settings =
  LintMap.iter f settings.explicit_settings

(* Fold over all lint kinds with an explicit setting *)
let fold f settings acc =
  LintMap.fold f settings.explicit_settings acc

(* Map over all lint kinds with an explicit setting *)
let map f settings =
  let new_explicit = LintMap.map f settings.explicit_settings in
  {settings with explicit_settings = new_explicit}

(* Merge two LintSettings, with rules in higher_precedence overwriting
 * rules in lower_precedencse. *)
let merge ~low_prec ~high_prec =
  if high_prec.all_encountered then high_prec
  else fold set_enabled high_prec low_prec

type parse_result =
| AllSetting of t
| EntryList of lint_kind list * (bool * Loc.t option)

(* Takes a list of labeled lines and returns the corresponding LintSettings.t if
 * successful. Otherwise, returns an error message along with the label of the
 * line it failed on. *)
let of_lines =

  let parse_value label = function
    | "on" -> Ok true
    | "off" -> Ok false
    | _ -> Error (label,
      "Invalid setting encountered. Valid settings are on and off.")
  in

  let eq_regex = Str.regexp "=" in
  let all_regex = Str.regexp "all" in

  let parse_line (loc, (label, line)) =
    match Str.split_delim eq_regex line with
    | [left; right] ->
      let left = left |> String.trim in
      let right = right |> String.trim in
      Result.bind (parse_value label right) (fun value ->
        match left with
        | "all" -> Ok (AllSetting (all_setting value))
        | _ ->
          try
            Ok (EntryList (kinds_of_string left, (value, Some loc)))
          with Not_found ->
            Error (label, (Printf.sprintf "Invalid lint rule \"%s\" encountered." left))
      )
    | _ -> Error (label,
      "Malformed lint rule. Properly formed rules contain a single '=' character.")
  in

  let add_settings keys value settings =
    List.fold_left (fun settings key -> set_enabled key value settings) settings keys
  in

  let rec loop acc = function
    | [] -> Ok acc
    | line::lines ->
      Result.bind (parse_line line)
        (fun result ->
          match result with
            | EntryList (keys, value) ->
              loop (add_settings keys value acc) lines
            | AllSetting setting ->
              if acc == default_settings then loop setting lines
              else Error (line |> snd |> fst,
                "\"all\" is only allowed as the first setting. Settings are order-sensitive.")
        )
  in

  let loc_of_line line =
    let open Loc in
    let start = {line; column = 0; offset = 0} in
    let _end = {line = line + 1; column = 0; offset = 0} in
    {source = None; start; _end}
  in

  fun lint_lines ->
    let locate_fun =
      let index = ref 0 in
      fun item ->
        let res = (loc_of_line !index, item) in
        index := !index + 1; res
    in

    (* Artificially locate the lines to detect unused lines *)
    let located_lines = List.map locate_fun lint_lines in
    let settings = loop default_settings located_lines in

    Result.bind settings (fun settings ->
        let used_locs = fold
          (fun _kind (_enabled, loc) acc ->
            Option.value_map loc ~f:(fun loc -> Loc.LocSet.add loc acc) ~default:acc)
          settings Loc.LocSet.empty
        in
        let first_unused = List.fold_left
          (fun acc (art_loc, (label, line)) ->
            match acc with
              | Some _ -> acc
              | None ->
                if Loc.LocSet.mem art_loc used_locs
                  || Str.string_match all_regex (String.trim line) 0
                then None else Some label
          ) None located_lines
        in
        match first_unused with
          | Some label -> Error (label, "Redundant argument. "
            ^ "The values set by this argument are completely overwritten.")
          | None ->
            (* Remove the artificial locations before returning the result *)
            Ok (map (fun (enabled, _loc) -> (enabled, None)) settings)
    )
