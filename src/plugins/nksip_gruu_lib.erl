%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc NkSIP GRUU Plugin Utilities
-module(nksip_gruu_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").
-include("nksip_registrar.hrl").

-export([find/2, update_gruu/1, check_gr/2, update_regcontact/4]).

-define(AES_IV, <<"12345678abcdefgh">>).


%% @private 
-spec update_gruu(nksip:response()) ->
    ok.

update_gruu(#sipmsg{srv_id=SrvId, contacts=Contacts, class={resp, Code, _},
                      cseq={_, Method}}) ->
    case Method=='REGISTER' andalso Code>=200 andalso Code<300 of
        true ->
            find_gruus(SrvId, Contacts);
        false ->
            ok
    end.


%% @private
find_gruus(SrvId, [#uri{ext_opts=Opts}|Rest]) ->
    HasPubGruu = case nklib_util:get_value(<<"pub-gruu">>, Opts) of
        undefined ->
            false;
        PubGruu ->
            case nksip_parse:ruris(nklib_util:unquote(PubGruu)) of
                [PubUri] ->
                    nksip_app:put({nksip_gruu_pub, SrvId}, PubUri),
                    true;
                _ ->
                    false
            end
    end,
    HasTmpGruu = case nklib_util:get_value(<<"temp-gruu">>, Opts) of
        undefined ->
            false;
        TempGruu ->
            case nksip_parse:ruris(nklib_util:unquote(TempGruu)) of
                [TempUri] ->
                    nksip_app:put({nksip_gruu_temp, SrvId}, TempUri),
                    true;
                _ ->
                    false
            end
    end,
    case HasPubGruu andalso HasTmpGruu of
        true ->
            ok;
        false ->
            find_gruus(SrvId, Rest)
    end;

find_gruus(_, []) ->
    ok.


%% @private
-spec find(nkserver:id(), nksip:uri()) ->
    [nksip:uri()].

find(SrvId, #uri{scheme=Scheme, user=User, domain=Domain, opts=Opts}) ->
    case lists:member(<<"gr">>, Opts) of
        true ->
            % It is probably a tmp GRUU
            case catch decrypt(User) of
                Tmp when is_binary(Tmp) ->
                    {{Scheme1, User1, Domain1}, InstId, Pos} = binary_to_term(Tmp),
                    [
                        nksip_registrar_lib:make_contact(Reg) 
                        || #reg_contact{meta=Meta}=Reg 
                        <- nksip_registrar_lib:get_info(SrvId, Scheme1, User1, Domain1),
                        nklib_util:get_value(nksip_gruu_instance_id, Meta)==InstId,
                        nklib_util:get_value(nksip_gruu_tmp_min, Meta, 0)=<Pos
                    ];
                _ ->
                    ?SIP_LOG(notice, "private GRUU not recognized: ~p", [User]),
                    nksip_registrar_lib:find(SrvId, Scheme, User, Domain)
            end;
        false ->
            case nklib_util:get_value(<<"gr">>, Opts) of
                undefined ->
                    nksip_registrar_lib:find(SrvId, Scheme, User, Domain);
                InstId ->
                    [
                        nksip_registrar_lib:make_contact(Reg) 
                            || #reg_contact{meta=Meta}=Reg 
                            <- nksip_registrar_lib:get_info(SrvId, Scheme, User, Domain),
                            nklib_util:get_value(nksip_gruu_instance_id, Meta)==InstId
                    ]
            end
    end.


check_gr(Contact, Req) ->
    #uri{user=User, opts=Opts} = Contact,
    #sipmsg{to={To, _}} = Req,
    case lists:member(<<"gr">>, Opts) of
        true ->
            case catch decrypt(User) of
                LoopTmp when is_binary(LoopTmp) ->
                    {{LScheme, LUser, LDomain}, _, _} = binary_to_term(LoopTmp),
                    case aor(To) of
                        {LScheme, LUser, LDomain} ->
                            throw({forbidden, "Invalid Contact"});
                        _ ->
                            ok
                    end;
                _ ->
                    ok
            end;
        false ->
            ok
    end.


%% @private
update_regcontact(RegContact, Base, Req, Opts) ->
    #reg_contact{contact=Contact, meta=Meta} = RegContact,
    #reg_contact{call_id=BaseCallId} = Base,
    #sipmsg{to={To, _}, call_id=CallId} = Req,
    Next = nklib_util:get_value(nksip_gruu_tmp_next, Meta, 0),
    Meta1 = case CallId of
        BaseCallId ->
            Meta;
        _ ->
            % We have changed the Call-ID for this AOR and index, invalidate all
            % temporary GRUUs
            nklib_util:store_value(nksip_gruu_tmp_min, Next, Meta)
    end,
    #uri{scheme=Scheme, ext_opts=ExtOpts} = Contact,
    InstId = case nklib_util:get_value(<<"+sip.instance">>, ExtOpts) of
        undefined ->
            <<>>;
        Inst0 ->
            nklib_util:hash(Inst0)
    end,
    Expires = nklib_util:get_integer(<<"expires">>, ExtOpts),
    case 
        InstId /= <<>> andalso Expires>0 andalso 
        lists:member({gruu, true}, Opts)
    of
        true ->
            case Scheme of
                sip ->
                    ok;
                _ ->
                    throw({forbidden, "Invalid Contact"})
            end,
            {AORScheme, AORUser, AORDomain} = aor(To),
            PubUri = #uri{
                scheme = AORScheme, 
                user = AORUser, 
                domain = AORDomain,
                opts = [{<<"gr">>, InstId}]
            },
            Pub = list_to_binary([$", nklib_unparse:uri3(PubUri), $"]),
            ExtOpts2 = nklib_util:store_value(<<"pub-gruu">>, Pub, ExtOpts),
            TmpBin = term_to_binary({aor(To), InstId, Next}),
            TmpUri = PubUri#uri{user=encrypt(TmpBin), opts=[<<"gr">>]},
            Tmp = list_to_binary([$", nklib_unparse:uri3(TmpUri), $"]),
            ExtOpts3 = nklib_util:store_value(<<"temp-gruu">>, Tmp, ExtOpts2),
            Contact3 = Contact#uri{ext_opts=ExtOpts3},
            Meta2 = nklib_util:store_value(nksip_gruu_instance_id, InstId, Meta1),
            Meta3 = nklib_util:store_value(nksip_gruu_tmp_next, Next+1, Meta2),
            RegContact#reg_contact{contact=Contact3, meta=Meta3};
        false ->
            RegContact
    end.


%% @private
aor(#uri{scheme=Scheme, user=User, domain=Domain}) ->
    {Scheme, User, Domain}.


%% @private
encrypt(Bin) ->
    <<Key:16/binary, _/binary>> = nksip_config:get_config(global_id),
    base64:encode(do_encrypt(Key, Bin)).


%% @private
decrypt(Bin) ->
    <<Key:16/binary, _/binary>> = nksip_config:get_config(global_id),
    do_decrypt(Key, base64:decode(Bin)).


do_encrypt(Key, Bin) ->
%%    crypto:block_encrypt(aes_cfb128, Key, ?AES_IV, Bin).
    crypto:crypto_one_time(aes_128_cfb128, Key, ?AES_IV, Bin, true). 

do_decrypt(Key, Dec) ->
%%    crypto:block_decrypt(aes_cfb128, Key, ?AES_IV, Dec).
 %%   crypto:block_decrypt(aes_cfb128, Key, ?AES_IV, Dec).
    crypto:crypto_one_time(aes_128_cfb128, Key, ?AES_IV, Dec, false). 



