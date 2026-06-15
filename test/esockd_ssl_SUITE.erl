%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(esockd_ssl_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("public_key/include/public_key.hrl").
-include_lib("eunit/include/eunit.hrl").

all() -> esockd_ct:all(?MODULE).

init_per_testcase(_TestCase, Config) ->
    CertFile = esockd_ct:certfile(Config),
    [{cert, pem_decode(CertFile)}|Config].

end_per_testcase(_TestCase, Config) ->
    Config.

pem_decode(CertFile) ->
    {ok, CertBin} = file:read_file(CertFile),
    [{'Certificate', DerCert, _}] = public_key:pem_decode(CertBin),
    DerCert.

cert(Config) -> proplists:get_value(cert, Config).

t_peer_cert_issuer(Config) ->
    esockd_ssl:peer_cert_issuer(cert(Config)).

t_peer_cert_subject_items(Config) ->
    esockd_ssl:peer_cert_subject_items(cert(Config), {0,9,2342,19200300,100,1,1}).

t_peer_cert_validity(Config) ->
    esockd_ssl:peer_cert_validity(cert(Config)).

t_peer_cert_common_name(Config) ->
    esockd_ssl:peer_cert_common_name(cert(Config)).

t_peer_cert_subject(Config) ->
    esockd_ssl:peer_cert_subject(cert(Config)).

t_peer_cert_subject_alt_names(_) ->
    ?assertEqual(
        #{
            dns => [<<"example.com">>, <<"www.example.com">>],
            ip => [<<"192.168.1.100">>, <<"2001:db8::1">>],
            email => [<<"device@example.com">>],
            uri => [<<"urn:device:123">>]
        },
        esockd_ssl:peer_cert_subject_alt_names(san_cert())
    ).

t_peer_cert_subject_alt_names_empty(_) ->
    ?assertEqual(
        #{
            dns => [],
            ip => [],
            email => [],
            uri => []
        },
        esockd_ssl:peer_cert_subject_alt_names(no_san_cert())
    ).

san_cert() ->
    cert_with_extensions([
        #'Extension'{
            extnID = ?'id-ce-subjectAltName',
            extnValue = [
                {dNSName, "example.com"},
                {dNSName, "www.example.com"},
                {iPAddress, [192, 168, 1, 100]},
                {iPAddress, [32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]},
                {rfc822Name, "device@example.com"},
                {uniformResourceIdentifier, "urn:device:123"}
            ]
        }
    ]).

no_san_cert() ->
    cert_with_extensions(asn1_NOVALUE).

cert_with_extensions(Extensions) ->
    Key = public_key:generate_key({namedCurve, secp521r1}),
    Subject = {rdnSequence, [
        [
            #'AttributeTypeAndValue'{
                type = ?'id-at-commonName',
                value = {printableString, "SAN Test"}
            }
        ]
    ]},
    TBS = #'OTPTBSCertificate'{
        version = v3,
        serialNumber = 1,
        signature = #'SignatureAlgorithm'{
            algorithm = ?'ecdsa-with-SHA256',
            parameters = Key#'ECPrivateKey'.parameters
        },
        issuer = Subject,
        validity = #'Validity'{
            notBefore = {generalTime, "20260101000000Z"},
            notAfter = {generalTime, "20270101000000Z"}
        },
        subject = Subject,
        subjectPublicKeyInfo = #'OTPSubjectPublicKeyInfo'{
            algorithm = #'PublicKeyAlgorithm'{
                algorithm = ?'id-ecPublicKey',
                parameters = Key#'ECPrivateKey'.parameters
            },
            subjectPublicKey = #'ECPoint'{point = Key#'ECPrivateKey'.publicKey}
        },
        extensions = Extensions
    },
    public_key:pkix_sign(TBS, Key).
