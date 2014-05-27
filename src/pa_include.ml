(* Ocsigen
 * http://www.ocsigen.org
 * Copyright (C) 2010-2011
 * Raphaël Proust
 * Pierre Chambart
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
*)

module Make(Syntax : Camlp4.Sig.Camlp4Syntax) = struct

  include Syntax

  let rec ctyp_unapply al =
    function
      | Ast.TyApp (_, f, a) -> ctyp_unapply (a :: al) f
      | f -> (f, al)

  class subst_var env = object (self)
    inherit Ast.map as super
    method ctyp ty = match ty with
    | <:ctyp@_loc< '$lid:a$ >> ->
      begin try List.assoc a env
      with Not_found -> ty end
    | ty -> super#ctyp ty
  end

  class subst_type env = object (self)
    inherit Ast.map as super
    method sig_item si = match si with
      | Ast.SgTyp (_loc, (Ast.TyDcl (_, lid, _, Ast.TyNil _, _)))
          when List.mem_assoc lid env -> <:sig_item< >>
      | si -> super#sig_item si
    method ctyp ty = match ty with
    | <:ctyp@_loc< $lid:lid$ >> when List.mem_assoc lid env ->
      let _, _, ty = List.assoc lid env in
      ty
    | Ast.TyApp (_loc, _, _) -> begin
        let (id, args) = ctyp_unapply [] ty in
        match id with
        | <:ctyp< $lid:lid$ >> when List.mem_assoc lid env ->
          let args = List.map self#ctyp args in
          let _loc, vars, ty = List.assoc lid env in
          let env =
            try List.combine vars args
            with _ -> Loc.raise _loc (Failure "Invalid type arity") in
          (new subst_var env)#ctyp ty
        | _ -> super#ctyp ty
      end
    | ty -> super#ctyp ty
  end

  let create_env wc =
    let varname = function
      | <:ctyp@_loc< '$lid:a$ >> -> a
      | _ -> assert false
    in
    let map_type wc = match wc with
      | <:with_constr< type $typ:ty1$ := $typ:ty2$ >> -> begin
          let id, vars = ctyp_unapply [] ty1 in
          match id with
          | <:ctyp< $lid:lid$ >> ->
            (lid, (Ast.loc_of_ctyp ty1,List.map varname vars, ty2))
          | _ -> assert false
        end
      | _ ->
          Loc.raise
            (Ast.loc_of_with_constr wc)
            (Failure "Unhandled substitution")
    in
    List.map map_type (Ast.list_of_with_constr wc [])

  let subst_type wc mt =
    let _loc = Ast.Loc.ghost in
    let env = create_env wc in
    (new subst_type env)#module_type mt

  let load_file f =
    let ic = open_in f in
    try
      let (items, stopped) =
        Gram.parse interf
          (Loc.mk  (f ^ " " ^ string_of_int (Random.int 1000000 )))
          (Stream.of_channel ic) in
      assert (stopped = None);
      close_in ic;
      items
    with
      | Not_found ->
        Printf.eprintf "Error: File not found (%s)\n" f;
        close_in ic;
        exit 1
      | e ->
        Printf.eprintf "%s\n" (Camlp4.ErrorHandler.to_string e);
        close_in ic;
        exit 1

  (* Extending syntax *)
      EXTEND Gram
      GLOBAL: module_type sig_item;

    sig_item: BEFORE "top"
      [ [ "include"; mt = module_type ->
      begin match mt with
      | <:module_type< sig $x$ end>> ->
            (* Hack: insert SgNil with a correct location, in order to
                     preserve comments locations *)
            Ast.(SgSem(_loc, SgNil _loc, x))
      | mt -> <:sig_item< include $mt$ >>
      end
        ] ];

    module_type: LEVEL "with"
      [ [ mt = SELF; "subst"; wc = with_constr ->
      <:module_type< $subst_type wc mt$ >> ] ];

    module_type: LEVEL "simple"
      [ [ mli = a_STRING ->
        let sourcedir = Filename.dirname (Loc.file_name _loc) in
        (<:module_type< sig $list:load_file (Filename.concat sourcedir mli)$ end >>)] ];

    END

end

module Id : Camlp4.Sig.Id = struct
  let name = "Include .mli as module signature."
  let version = "0.1"
end

module M = Camlp4.Register.OCamlSyntaxExtension(Id)(Make)
