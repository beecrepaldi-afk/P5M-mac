# Takion v20 — notas de interoperabilidade

Estado em 08/10/2026. Notas de comportamento do protocolo, obtidas por
análise estática do PS Remote Play oficial 9.5.0 para Mac e confirmadas
contra o PS5 com a sonda `P5M_TAKION_PROBE`. Este arquivo não contém código
da Sony; só descreve formatos e a ordem das mensagens.

## Negociação

- O app oficial suporta Takion v7–v20. O chiaki fala v12 fixa no stream do
  PS5 (`lib/src/streamconnection.c`, `takion_info.protocol_version`) e só
  negocia (pedindo v9) na conexão senkusha.
- No stream, o app oficial, logo depois do takion connect e antes do `BIG`,
  manda `TAKIONPROTOCOLREQUEST` (tipo 31) com a lista de versões e espera
  `TAKIONPROTOCOLREQUESTACK` (tipo 32). Sem resposta, usa a versão padrão.
  A versão escolhida também vai em `BigPayload.client_version`.
- **Confirmado:** pedindo 12..20, o PS5 respondeu "20" em ~2 ms
  (sessão de 08/10/2026 02:23). A sonda sai sem stream: com
  `P5M_TAKION_PROBE=1` (ou `a-b`), `streamconnection.c` faz só o pedido,
  anota `[takion-probe] console chose Takion version N` e encerra.

## O que muda por versão (v12 → v20)

### v17: cabeçalho estendido (todos os tipos de pacote)

Logo depois do byte de tipo entram **8 bytes**; todo o resto do pacote
desloca 8 bytes (inclusive tag/GMAC e key_pos, por exemplo o tag do
feedback passa de 8 para 0x10, e o pacote de congestionamento passa de
15 para 23 bytes).

Conteúdo, big-endian:
- `u32` carimbo de tempo do envio, em **microssegundos** de um relógio
  monotônico iniciado com a conexão (trunca em 32 bits; só diferenças
  importam);
- `u32` contador de pacotes enviados, incrementado a cada envio.

Os serializadores escrevem zeros ali e o campo é preenchido no envio.
Na recepção, para cada pacote, o app calcula a variação do atraso:
`(agora − agora_anterior) − (ts_remoto − ts_remoto_anterior)`, isto é,
controle de congestionamento por gradiente de atraso (estilo WebRTC).

### v18: canal ExtMessage

Novas funções de protocolo e um `ExtMessageHeader`. É o canal das
mensagens protobuf `ExtMessage` com os tipos `RTT`
(`entryIndex`, `origSendTimestampUs`), `CLIENTMETRIC`, `WIFIMETRICS`
(sinal, canal, taxas) e `CONGESTIONCONTROLCOORDINATOR` (`cccdata`, opaco).

### Cabeçalho AV (vídeo/áudio)

Offsets a partir do início do pacote (byte 0 = tipo; 2 vídeo, 3 áudio).
Na v20 é o layout da v12 deslocado 8 bytes, mais três campos novos:

| v20 | conteúdo |
|---|---|
| 1–8 | cabeçalho estendido |
| 9 | `u16` packet_index |
| 0xb | `u16` frame_index |
| 0xd | `u32` unidades: vídeo igual à v12 (11/11/10 bits); **áudio** passa a ser índice 8 bits, total−1 8 bits, **campo novo de 4 bits** (bits 12–15) e FEC em 12 bits (era 16) |
| 0x11 | codec |
| 0x12 | tag/GMAC |
| 0x16 | `u32` key_pos |
| 0x1a | vídeo: `u16` word_at_0x18; 0x1c: adaptive_stream_index (bits 5–7) e **flag nova no bit 0** |
| depois | estruturas NALU (se o bit 4 do tipo) e, no áudio, o byte de haptics (0x02) seguido de um byte que na v20 se divide em **dois nibbles** (o alto é novo) |

O que os três campos novos significam ainda não foi identificado.

### Feedback (cliente → PS5)

- v14: nova mensagem de 4 bytes + até 16 valores `u16`.
- v16: o estado do controle passa de 25 para **28 bytes** (3 bytes novos
  no fim, um deles com um bit extra).
- v16/v19/v20: `PadInfoEvent` ganha 1 byte no fim.
- v16: `RumbleEvent` e `PadTriggerEvent` novos; v17: `MouseInfoEvent`
  (tipo de pacote 13: cabeçalho estendido + `u8` + `u32`).
- v15: pacote `GenericData` (tipo 12: cabeçalho estendido + 5 campos,
  30 bytes no total).

## Correção: o cabeçalho estendido é só da v20

A tabela de recursos por versão do app oficial e as tabelas de tamanho de
cabeçalho (vídeo 0x17→0x1f, áudio 0x14→0x1c, feedback 0xb→0x13, só na v20)
mostram que os 8 bytes extras existem **apenas na v20**, não a partir da v17.
Ordem dos campos confirmada no assembly: primeiro o tempo em µs, depois o
contador (começa em 0). O app preenche o cabeçalho e só então calcula o GMAC.

**Exceção (achada no primeiro teste, 08/10 02:50):** os pacotes de controle
baseados em chunks (tipo 0, e também 4 e 8) **não** levam o cabeçalho
estendido na v20: o serializador escreve o byte de tipo e o chunk logo em
seguida, como na v12. Só AV, feedback, congestionamento e os tipos novos
o levam. Com os 8 bytes no tipo 0, o PS5 descartou o `BIG` em silêncio
(reenvios até o tempo de espera do `BANG`).

## Troca de chaves: P-521 a partir da v13

No app oficial, a função que prepara o ECDH consulta a tabela de recursos
por versão (recurso 5). Até a v12 usa a curva de 256 bits (segredo de
32 bytes); da v13 em diante usa **P-521** (segredo de 0x42 = 66 bytes).
Segundo teste (08/10 02:56): com o controle sem cabeçalho estendido, o PS5
aceitou o `BIG` e mandou `STREAMINFO`, mas o `BANG` não decodificou no P5M.
A causa provável é a chave pública P-521 (133 bytes), que não cabe no buffer
de 128 bytes. Qualquer versão acima da 12 exige portar o ECDH para P-521,
incluindo a chave do `BIG`, a assinatura e a derivação das chaves do gkcrypt
com o segredo de 66 bytes.

Mapeado depois: a curva nova é a secp521r1 (NID 716; a antiga é a secp256k1,
NID 714, igual à do chiaki). A chave pública vai não comprimida (133 bytes) e
o segredo é a coordenada x (66 bytes). A assinatura continua sendo o
HMAC-SHA256 da chave pública com a handshake key, e a derivação das chaves do
gkcrypt também não muda (HMAC-SHA256 de `01 idx 00 handshake_key 01 00`),
só que com o segredo de 66 bytes. A versão do Takion só muda o gkcrypt
abaixo da v7.

Implementado em 08/10: `chiaki_ecdh_init_p521`, `chiaki_gkcrypt_init_secret`,
chave P-521 por conexão em `streamconnection.c` quando a v20 é escolhida, e o
teste `/chiaki/gkcrypt/ecdh_p521`.

## Áudio na v20 (confirmado com pacotes reais, 08/10 03:06)

Os bits 12–15 do campo de unidades do áudio são um **modo**. O PS5 manda o
modo 2. Nesse modo, os 12 bits baixos são a quantidade de unidades FEC
(redundância), todas as unidades têm o mesmo tamanho (bytes de dados / total
de unidades), e as unidades de áudio são total − FEC. Exemplo real: total 3,
campo 0x2002, 240 bytes, ou seja 1 unidade de áudio + 2 de FEC, de 80 bytes
cada. Na v12, o tamanho da unidade vinha no byte alto do campo. O P5M traduz
o modo 2 para o layout da v12 em `av_packet_parse`.

## Implementação experimental (08/10/2026, sem commit)

- `P5M_TAKION_V20=1`: logo depois do takion connect, `streamconnection.c`
  oferece {12, 20}. Se o PS5 escolher 20, espera 20 ms (para o ack da
  resposta sair ainda no formato antigo) e chama `chiaki_takion_set_version`.
  Sem resposta ou com 12, segue na v12 como antes.
- `takion.c`: offsets de MAC/key_pos +8, cabeçalho estendido escrito antes do
  GMAC em controle, ack, congestionamento, feedback e microfone; recepção
  com offsets +8 (sem cortar o pacote, para a verificação adiada de MAC);
  leitor AV v20 (FEC do áudio em 12 bits, marcador de haptics no nibble baixo).
- `[takion-v20] 10s: ...` no diário: variação do atraso de ida medida pelos
  carimbos do PS5.
- Informação do controle aceita os tamanhos v20 (0x1a e 0x12).
- Teste `/chiaki/takion/av_packet_parse_v20`.

## Primeira sessão completa em v20 (08/10 03:10)

Vídeo 1080p HEVC a 60 fps, decodificação sem erros, áudio com 1000 quadros a
cada 10 s (sem falhar), FEC de vídeo não usado, sem perda. A variação do atraso de ida
ficou em média em ~0,41 ms (máx. 30–66 ms). Em aberto: o "rtt max" do relatório
de bitrate fica em 160–200 em todas as sessões v20, ainda sem uma base v12
equivalente para comparar. Hápticos e controle ainda não foram confirmados
pelo dono.

## Próximos passos

1. Mapear o cabeçalho dos pacotes de dados/controle (tipo 0) e do feedback
   na v20 com o mesmo método.
2. Implementar a v20 no P5M atrás de uma opção desligada por padrão: pedir
   a versão, ajustar offsets (+8), preencher o cabeçalho estendido nos
   envios, estado do controle de 28 bytes.
3. Comparar no diário v12 × v20 (latência, perda, qualidade) antes de
   pensar em padrão.

## Gatilhos adaptativos na v20 (08/10 03:14)

A mensagem de dados de gatilho (tipo 11) chega com 33 bytes na v20: 8 bytes
extras na frente e, depois deles, exatamente os 25 bytes da v12 (modos em
1–2, efeito esquerdo em 5–14, direito em 15–24). O P5M lia os modos dentro
dos 8 bytes extras, por isso os gatilhos ficavam estranhos. Corrigido em
`stream_connection_takion_data_trigger_effects`: na v20 pula os 8 bytes.

## v20 como padrão (08/10, a pedido do dono)

Depois de vídeo, áudio, vibração e gatilhos confirmados, a negociação passou
a rodar sempre no PS5. `P5M_TAKION_V20=0` volta à v12. Se o console não
responder em 1 s, o stream segue na v12, como antes.
