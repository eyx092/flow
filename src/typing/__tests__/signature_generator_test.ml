(**
 * Copyright (c) 2013-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)


open OUnit2

module Translate = Estree_translator.Translate (Json_of_estree) (struct
  (* TODO: make these configurable via CLI flags *)
  let include_comments = true
  let include_locs = true
end)

let pretty_print program =
  Source.contents @@ Pretty_printer.print ~source_maps:None ~skip_endline:true @@
    Js_layout_generator.program_simple program

let print_ast program =
  Hh_json.json_to_string ~pretty:true @@ Translate.program program

let verify_and_generate ?prevent_munge ?ignore_static_propTypes contents =
  let contents = String.concat "\n" contents in
  let program = Signature_verifier_test.parse contents in
  let signature = match Signature_builder.program ~module_ref_prefix:None program with
    | Ok signature -> signature
    | Error _ -> failwith "Signature builder failure!" in
  Signature_builder.Signature.verify_and_generate ?prevent_munge ?ignore_static_propTypes
    signature program

let mk_signature_generator_test contents expected_msgs =
  begin fun ctxt ->
    let msgs = match verify_and_generate contents with
      | Ok program ->
        String.split_on_char '\n' @@ pretty_print program
      | Error errors ->
        List.map Signature_builder_deps.Error.debug_to_string @@
          Signature_builder_deps.ErrorSet.elements errors
    in
    let printer v = "\n" ^ (String.concat "\n" v) in
    assert_equal ~ctxt
      ~cmp:(Signature_verifier_test.eq printer)
      ~printer
      ~msg:"Results don't match!"
      expected_msgs msgs
  end

let mk_verified_signature_generator_test ?prevent_munge ?ignore_static_propTypes contents =
  begin fun ctxt ->
    let msgs = match verify_and_generate ?prevent_munge ?ignore_static_propTypes contents with
      | Ok _program -> []
      | Error errors ->
        List.map Signature_builder_deps.Error.debug_to_string @@
          Signature_builder_deps.ErrorSet.elements errors
    in
    let printer v = String.concat "\n" v in
    assert_equal ~ctxt
      ~cmp:(Signature_verifier_test.eq printer)
      ~printer
      ~msg:"Results don't match!"
      [] msgs
  end

let verified_signature_generator_tests =
  List.fold_left (fun acc -> fun (
    (prevent_munge, ignore_static_propTypes, name),
    contents,
    error_msgs,
    _other_msgs) ->
    if error_msgs = [] then
      let name = "verified_" ^ name in
      (name >:: mk_verified_signature_generator_test ?prevent_munge ?ignore_static_propTypes
         contents) :: acc
    else acc
  ) [] Signature_verifier_test.tests_data

let tests = "signature_generator" >::: ([
  "dead_type" >:: mk_signature_generator_test
    ["type U = number"]
    [];

  "dead_declare_type" >:: mk_signature_generator_test
    ["declare type U = number"]
    [];

  "dead_types_transitive" >:: mk_signature_generator_test
    ["type U = number";
     "declare type T = U"]
    [];

  "export_type_alias" >:: mk_signature_generator_test
    ["type U = number";
     "export type T = U"]
    ["type U = number;";
     "type T = U;";
     "export type {T};"]; (* TODO: change of spaces *)

  "export_type_specifier" >:: mk_signature_generator_test
    ["type U = number";
     "export type { U }"]
    ["type U = number;";
     "export type {U};"];

  "export_type_specifier_local" >:: mk_signature_generator_test
    ["type U = number";
     "export type { U as U2 }"]
    ["type U = number;";
     "export type {U as U2};"];

  "export_type_specifier_remote" >:: mk_signature_generator_test
    ["export type { K } from './foo'"]
    ["export type {K} from \"./foo\";"]; (* TODO: change of quotes *)

  "export_type_specifier_remote_local1" >:: mk_signature_generator_test
    ["export type { K as K2 } from './foo'"]
    ["export type {K as K2} from \"./foo\";"];

  "export_type_specifier_remote_local2" >:: mk_signature_generator_test
    ["type K = number";
     "export type { K as K2 } from './foo'"]
    ["export type {K as K2} from \"./foo\";"];

  "export_type_specifier_remote_local3" >:: mk_signature_generator_test
    ["export type K = number";
     "export type { K as K2 } from './foo'"]
    ["type K = number;";
     "export type {K};";
     "export type {K as K2} from \"./foo\";"];

  "export_type_batch" >:: mk_signature_generator_test
    ["export type * from './foo'"]
    ["export type * from \"./foo\";"];

  "dead_var" >:: mk_signature_generator_test
    ["var x: number = 0"]
    [];

  "dead_declare_var" >:: mk_signature_generator_test
    ["declare var x: number"]
    [];

  "dead_transitive" >:: mk_signature_generator_test
    ["class C { }";
     "var x: C = new C"]
    [];

  "module_exports_function_expression" >:: mk_signature_generator_test
    ["module.exports = function() { }"]
    ["declare module.exports: () => void;"];

  "module_exports_literal" >:: mk_signature_generator_test
    ["module.exports = 'hello'"]
    ["declare module.exports: 'hello';"];

  "module_exports_object" >:: mk_signature_generator_test
    ["module.exports = { x: 'hello' }"]
    ["declare module.exports: {|x: 'hello'|};"];

  "module_exports_array_one" >:: mk_signature_generator_test
    ["module.exports = ['hello']"]
    ["declare module.exports: Array<'hello'>;"];

  "module_exports_array_many" >:: mk_signature_generator_test
    ["module.exports = ['hello', 42]"]
    ["declare module.exports: Array<'hello' | 42>;"];

  "module_exports_class_expression" >:: mk_signature_generator_test
    ["module.exports = class { m(x: number): number { return x; } }"]
    ["declare class $1 {m(x: number): number}";
     "declare module.exports: typeof $1;"]; (* outlining *)

  "module_exports_named_class_expression" >:: mk_signature_generator_test
    ["module.exports = class C { m(x: C): C { return x; } }"]
    ["declare class C {m(x: C): C}";
     "declare module.exports: typeof C;"]; (* outlining *)

  "module_exports_require" >:: mk_signature_generator_test
    ["module.exports = require('./foo')"]
    ["const $1 = require(\"./foo\");";
     "declare module.exports: typeof $1;"]; (* outlining *)

  "module_exports_import" >:: mk_signature_generator_test
    ["module.exports = import('./foo')"]
    ["import * as $1 from \"./foo\";";
     "declare module.exports: typeof $1;"]; (* outlining *)

  "module_exports_bindings" >:: mk_signature_generator_test
    ["function foo() { }";
     "class C { }";
     "const x: number = 0";
     "const o = { p: x };";
     "module.exports = { foo, C, x, p: o.p }"]
    ["declare function foo(): void;";
     "declare class C {}";
     "declare var x: number;";
     "declare var o: {|p: typeof x|};";
     "declare module.exports: {|";
     "  foo: typeof foo,";
     "  C: typeof C,";
     "  x: typeof x,";
     "  p: typeof o.p,";
     "|};"];

  "declare_module_exports" >:: mk_signature_generator_test
    ["declare module.exports: () => void"]
    ["declare module.exports: () => void;"];

  "export_default_expression" >:: mk_signature_generator_test
    ["export default function(x: number): number { return x; }"]
    ["declare export default (x: number) => number;"];

  "declare_export_default_type" >:: mk_signature_generator_test
    ["declare export default (number) => number"]
    ["declare export default (number) => number;"];

  "export_default_function_declaration" >:: mk_signature_generator_test
    ["export default function foo(): void { }"]
    ["declare function foo(): void;";
     "export {foo as default};"];

  "export_default_class_declaration" >:: mk_signature_generator_test
    ["export default class C { x: number = 0; }"]
    ["declare class C {x: number}";
     "export {C as default};"];

  "declare_export_default_function_declaration" >:: mk_signature_generator_test
    ["declare export default function foo(): void;"]
    ["declare function foo(): void;";
     "export {foo as default};"];

  "declare_export_default_class_declaration" >:: mk_signature_generator_test
    ["declare export default class C { x: number; }"]
    ["declare class C {x: number}";
     "export {C as default};"];

  "export_function_declaration" >:: mk_signature_generator_test
    ["export function foo(): void { }"]
    ["declare function foo(): void;";
     "export {foo};"];

  "export_class_declaration" >:: mk_signature_generator_test
    ["export class C { x: number = 0; }"]
    ["declare class C {x: number}";
     "export {C};"];

  "declare_export_function_declaration" >:: mk_signature_generator_test
    ["declare export function foo(): void;"]
    ["declare function foo(): void;";
     "export {foo};"];

  "declare_export_class_declaration" >:: mk_signature_generator_test
    ["declare export class C { x: number; }"]
    ["declare class C {x: number}";
     "export {C};"];

  "export_specifier" >:: mk_signature_generator_test
    ["var x: number = 0";
     "export { x }"]
    ["declare var x: number;";
     "export {x};"];

  "export_specifier_local" >:: mk_signature_generator_test
    ["var x: number = 0";
     "export { x as x2 }"]
    ["declare var x: number;";
     "export {x as x2};"];

  "export_specifier_remote" >:: mk_signature_generator_test
    ["export { k } from './foo'"]
    ["export {k} from \"./foo\";"];

  "export_specifier_remote_local1" >:: mk_signature_generator_test
    ["export { k as k2 } from './foo'"]
    ["export {k as k2} from \"./foo\";"];

  "export_specifier_remote_local2" >:: mk_signature_generator_test
    ["function k() { }";
     "export { k as k2 } from './foo'"]
    ["export {k as k2} from \"./foo\";"];

  "export_specifier_remote_local3" >:: mk_signature_generator_test
    ["export function k() { }";
     "export { k as k2 } from './foo'"]
    ["declare function k(): void;";
     "export {k};";
     "export {k as k2} from \"./foo\";"];

  "export_batch" >:: mk_signature_generator_test
    ["export * from './foo'"]
    ["export * from \"./foo\";"];

  "export_batch_local" >:: mk_signature_generator_test
    ["export * as Foo from './foo'"]
    ["export * as Foo from \"./foo\";"];

  "import_default" >:: mk_signature_generator_test
    ["import C from './foo'";
     "declare module.exports: C"]
    ["import C from \"./foo\";";
     "declare module.exports: C;"];

  "import_specifier" >:: mk_signature_generator_test
    ["import { C } from './foo'";
     "declare module.exports: C"]
    ["import {C} from \"./foo\";";
     "declare module.exports: C;"];

  "import_specifier_local" >:: mk_signature_generator_test
    ["import { C as C2 } from './foo'";
     "declare module.exports: C2"]
    ["import {C as C2} from \"./foo\";";
     "declare module.exports: C2;"];

  "import_specifier_local_dead" >:: mk_signature_generator_test
    ["import { C as C2 } from './foo'";
     "declare module.exports: C"]
    ["declare module.exports: C;"];

  "import_batch" >:: mk_signature_generator_test
    ["import * as Foo from './foo'";
     "declare module.exports: Foo.C"]
    ["import * as Foo from \"./foo\";";
     "declare module.exports: Foo.C;"];

  "import_type_default" >:: mk_signature_generator_test
    ["import type C from './foo'";
     "declare module.exports: C"]
    ["import type C from \"./foo\";";
     "declare module.exports: C;"];

  "import_type_specifier" >:: mk_signature_generator_test
    ["import type { T } from './foo'";
     "declare module.exports: T"]
    ["import type {T} from \"./foo\";";
     "declare module.exports: T;"];

  "import_type_specifier2" >:: mk_signature_generator_test
    ["import { type T } from './foo'";
     "declare module.exports: T"]
    ["import type {T} from \"./foo\";"; (* TODO: change of specifier kind *)
     "declare module.exports: T;"];

  "import_type_specifier_local" >:: mk_signature_generator_test
    ["import type { T as T2 } from './foo'";
     "declare module.exports: T2"]
    ["import type {T as T2} from \"./foo\";";
     "declare module.exports: T2;"];

  "import_type_specifier_local2" >:: mk_signature_generator_test
    ["import { type T as T2 } from './foo'";
     "declare module.exports: T2"]
    ["import type {T as T2} from \"./foo\";";
     "declare module.exports: T2;"];

  "import_type_specifier_local_dead" >:: mk_signature_generator_test
    ["import type { T as T2 } from './foo'";
     "declare module.exports: T"]
    ["declare module.exports: T;"];

  "import_typeof_specifier" >:: mk_signature_generator_test
    ["import { typeof x as T2 } from './foo'";
     "declare module.exports: T2"]
    ["import typeof {x as T2} from \"./foo\";";
     "declare module.exports: T2;"];

  "import_dynamic" >:: mk_signature_generator_test
    ["import './foo'"]
    [];

  "require" >:: mk_signature_generator_test
    ["const Foo = require('./foo')";
     "declare module.exports: Foo.C"]
    ["const Foo = require(\"./foo\");";
     "declare module.exports: Foo.C;"];

  "require_destructured" >:: mk_signature_generator_test
    ["const { C } = require('./foo')";
     "declare module.exports: C"]
    ["const {C} = require(\"./foo\");";
     "declare module.exports: C;"];

  "require_destructured_local" >:: mk_signature_generator_test
    ["const { C: C2 } = require('./foo')";
     "declare module.exports: C2"]
    ["const {C: C2} = require(\"./foo\");";
     "declare module.exports: C2;"];

  "require_destructured_local_dead" >:: mk_signature_generator_test
    ["const { C: C2 } = require('./foo')";
     "declare module.exports: C"]
    ["declare module.exports: C;"];

  "composite" >:: mk_signature_generator_test
    ["export type T = number";
     "type U = T"; (* reachable *)
     "import { type V } from './foo'"; (* dead *)
     "type W = [U, V]"; (* dead *)
     "function foo() { return [0, 0]; }"; (* dead *)
     "class B { +x: T = 0; m() { (foo(): W); } }"; (* reachable, but as declaration *)
     "export interface A { +x: U; }";
     "module.exports = function(x: B): A { return x; }"]
    ["type T = number;";
     "type U = T;";
     ""; (* TODO: pretty printing adds newlines for dead stuff *)
     "declare class B {+x: T, m(): void}";
     "interface A {+x: U}";
     "export type {T};";
     "";
     "export type {A};";
     "declare module.exports: (x: B) => A;"];

  "class_statics" >:: mk_signature_generator_test
    ["export class C {";
     "  static x: number = 0;";
     "  static foo(): void { }";
     "}"]
    ["declare class C {static x: number, static foo(): void}";
     "export {C};"];

  "class_statics2" >:: mk_signature_generator_test
    ["export class C {";
     "  foo: () => void;";
     "  static foo(): void { }";
     "}"]
    ["declare class C {foo: () => void, static foo(): void}";
     "export {C};"];

  "class_implements" >:: mk_signature_generator_test
    ["interface I {";
     "  foo(x?: string): void;";
     "}";
     "export class C implements I {";
     "  foo(x?: string): void { }";
     "}"]
    ["interface I {foo(x?: string): void}";
     "declare class C {foo(x?: string): void}";
     "export {C};"];

  "function_overloading" >:: mk_signature_generator_test
    ["declare function foo<T>(x: T): void;";
     "declare function foo<T,S>(x: T): void;";
     "export function foo<T,S,R>(x: T): void { }"]
    ["declare function foo<T>(x: T): void;";
     "declare function foo<T, S>(x: T): void;";
     "declare function foo<T, S, R>(x: T): void;";
     "export {foo};"];

    "function_overloading2" >:: mk_signature_generator_test
      ["declare export function foo<A>(x?: null, y?: null): void;";
       "declare export function foo<A,B>(x: null, y?: null): void;"]
      ["declare function foo<A>(x?: null, y?: null): void;";
       "declare function foo<A, B>(x: null, y?: null): void;";
       "export {foo};"];

  "opaque_type" >:: mk_signature_generator_test
    ["declare export opaque type T1";
     "declare export opaque type T2: number";
     "opaque type T3 = number"; (* dead *)
     "export opaque type T4: number = T3";
     "opaque type T5 = number";
     "export opaque type T6: T5 = number";
    ]
    ["declare opaque type T1;";
     "declare opaque type T2: number;";
     "";
     "declare opaque type T4: number;";
     "declare opaque type T5;";
     "declare opaque type T6: T5;";
     "export type {T1};";
     "export type {T2};";
     "";
     "export type {T4};";
     "";
     "export type {T6};"];

  "import_then_destructure" >:: mk_signature_generator_test
    ["import Foo from 'foo';";
     "const { Bar } = Foo;";
     "module.exports = Bar;"]
    ["import Foo from \"foo\";";
     "declare var Bar: typeof Foo.Bar;";
     "declare module.exports: typeof Bar;"];

  "import_then_destructure2" >:: mk_signature_generator_test
    ["import Foo from 'foo';";
     "const { Foo: Bar } = { Foo };";
     "module.exports = Bar;"]
    ["import Foo from \"foo\";";
     "declare var Bar: typeof $1.Foo;";
     "declare var $1: {|Foo: typeof Foo|};";
     "declare module.exports: typeof Bar;"];

  "optional_param" >:: mk_signature_generator_test
    ["module.exports = function(x?: number) { }"]
    ["declare module.exports: (x?: number) => void;"];

  "optional_param_default" >:: mk_signature_generator_test
    ["module.exports = function(x: number = 0) { }"]
    ["declare module.exports: (x?: number) => void;"];

  "optional_destructured_param_default" >:: mk_signature_generator_test
    ["module.exports = function({ x }: { x: number } = { x: 0 }) { }"]
    ["declare module.exports: (_?: {x: number}) => void;"];

  "array_summary_number" >:: mk_signature_generator_test
    ["module.exports = [1, 2, 3]"]
    ["declare module.exports: Array<number>;"];

  "array_summary_array" >:: mk_signature_generator_test
    ["module.exports = [[1, 2], [3]]"]
    ["declare module.exports: Array<Array<number>>;"];

  "array_summary_object" >:: mk_signature_generator_test
    ["module.exports = [{ x: 1 }, { x: 2 }]"]
    ["declare module.exports: Array<{|x: number|}>;"];

  "array_summary_object_array" >:: mk_signature_generator_test
    ["module.exports = [{ x: [1, 2] }, { x: [3] }]"]
    ["declare module.exports: Array<{|x: Array<number>|}>;"];

] @ verified_signature_generator_tests)
