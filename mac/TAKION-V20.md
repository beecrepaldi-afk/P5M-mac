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

## Tabela de recursos por versão (app oficial 9.5.0, análise de 08/10)

Análise estática do binário arm64 no Ghidra; nada da Sony foi copiado. A
função que responde "a versão V tem o recurso N?" recebe `(N, V)` e é uma
tabela fixa:

| Versão | Recursos ligados |
|---|---|
| 9 | 0–4 |
| 10 | 0–3, 5 (sem o 4) |
| 11 | 0–4, 6 (sem o 5) |
| 12 | 0–4, 6, 7 (sem o 5) |
| 13, 14 | 0–7 |
| 15, 16, 17 | 0–12 |
| 18 | 0–15 |
| 19 | 0–16 |
| 20 | 0–18 |

**Da v13 em diante cada versão só acrescenta recursos; a v20 tem tudo o que
as anteriores têm.** Os únicos "buracos" estão na v10–v12 (recursos 4 e 5).

O que cada recurso controla, pelo código em volta das consultas (confiança
entre parênteses; os números 0, 7, 14 e 18 não aparecem consultados):

- 1: autenticação/cifra por pacote; descarta pacote que falha (alta).
- 2: caminho de mensagens de controle tipo 10 (baixa).
- 3: cria um objeto de stream/codec de 0x248 bytes (baixa).
- 4: mensagem direta de alternar mute do microfone (`sendMicMute`) (média).
- 5: escolha de callback e buffers de chave; casa com a troca P-521 (baixa).
- 6: quadro de vídeo/áudio em subquadros (baixa).
- 8: `sendGenericControlDataPayload`, dentro do recurso 4 (baixa).
- 9: detecção de quadro tipo 9 no codec 6 (baixa).
- 10: resposta de 9 bytes (controle tipo 3) ao `streaminfo` (média).
- 11: byte extra 0x02 depois do marcador 0x21 (média-baixa).
- 12: mensagem de controle tipo 0x1d (baixa).
- 13: mensagem nova tipo 0x0e, enviada e recebida (média).
- 15: aceita mensagem recebida tipo 6; sem o recurso, ela é descartada (média).
- 16: `AUDIOSTATE availableBits` acima de 0xff (média-alta).
- 17: cabeçalho estendido de 8 bytes; só a v20 (alta, confirma a seção acima).

Recursos da v20 que o P5M ainda não usa (candidatos): 4/8 (mute do microfone
e dados de controle genéricos), 13 (mensagem 0x0e), 15 (mensagem tipo 6 do
console), 16 (estado de áudio).

## Áudio multicanal (5.1/7.1), teste de 08/10 à tarde

Experimental, ligado só por `P5M_AUDIO_CHANNELS=n` (0 estéreo, 1 5.1, 2 7.1,
3 7.1.4, 4 estéreo alternativo). Sem a variável nada muda.

**Como o cliente pede.** Duas coisas, como o app oficial (9.5.0):

1. No JSON de lançamento (BIG), na raiz: `"audioChannelNumRP": n` e
   `"audioSettings": {"audioChannels": [{"name": "main", "fecMode": 1,
   "settings": [5 perfis]}]}`. Cada perfil tem `channels`, `sampleRate` 48000,
   `samplesPerFrame` 480, `bitrate` (kbps), `isRawPcm` e `profileEnumType`
   0–4. Canais por perfil, pela tabela do app: 2, 6, 8, 12, 2. A tabela de
   bitrate do app só existe em execução; o P5M usa 32 kbps por canal (o
   estéreo de hoje é 64).
2. Depois do STREAMINFOACK: TakionMessage tipo 33 (AUDIOSTATE) com
   `audio_state_type` 6 (CHANNELNUM) e 1 byte = n. **Sozinho não faz nada**;
   o que liga o multicanal é o JSON de lançamento.

O app do Mac manda também, ao receber o STREAMINFO, um AUDIOSTATE tipo 1
(FLAGS) de 9 bytes: byte 0 = 0, uint32 LE `availableBits` = 3 no byte 1 e
zeros nos bytes 5–8. Sem o recurso 16 da tabela, `availableBits` acima de
0xff é cortado para 0xff (há um log disso no app).

**O que o PS5 responde.**

- O STREAMINFO continua dizendo 2 canais; não serve para saber o formato.
  Ele lista as faixas de áudio: tipo 0 (jogo, Opus 48 kHz) e tipos 2–5 (PCM
  cru, 2 canais, 16 bits, 3000 Hz, 30 amostras = haptics, um por controle).
- O byte de tipo do pacote de áudio (v12+) tem no nibble alto o número de
  canais: `0x20` estéreo, `0x60` 5.1; `0x22` são os haptics.
- No 5.1 o campo de unidades da v20 vem no **modo 1** (bits 12–15 = 1,
  12 bits baixos = nº de unidades FEC): cada pacote leva uma unidade inteira.
  Com 192 kbps são 3 pacotes por quadro de 10 ms: a fonte (242 bytes) e duas
  de FEC (244 bytes).
- A fonte começa com 2 bytes (`00 02` em todas as sessões) e depois vem um
  pacote Opus multistream. O primeiro byte da primeira stream é `f4` (CELT
  48 kHz, 10 ms, estéreo).
- As unidades FEC são Reed-Solomon em GF(256), polinômio 0x11d: a primeira
  é a fonte multiplicada por x⁻¹ byte a byte (`f4`→`7a`, `49`→`aa`,
  `00 02`→`00 01`). O P5M ainda as ignora.
- Arranjo das streams no 5.1: 4 streams, 2 em estéreo (pares primeiro),
  mapeamento identidade. O app oficial também usa mapeamento identidade de
  até 12 canais. O P5M deduz streams/pares no primeiro pacote, pelo formato
  autodelimitado (RFC 6716, apêndice B).

**Resultado.** O P5M pede, recebe, decodifica e toca 6 canais sem falhas
(~2,9 milhões de amostras a cada 10 s, nenhuma falta de áudio). Saída pelo
CoreAudio com layout WAVE 5.1 e o mixer espacial nos alto-falantes do Mac.

**Mas o PS5 só preenche L/R.** Com Homem-Aranha 2, os canais 2–5 vieram em
silêncio digital (−180 dB) em todas as sessões, e o cabeçalho ficou `00 02`
(provavelmente "2 canais ativos"). Descartado: pedido só por AUDIOSTATE,
jogo sem surround, jogo aberto antes da sessão (reiniciado dentro dela) e
saída do console em 2 canais (trocada para 7.1), Dolby Atmos no console
(testado em PCM linear) e o aparelho declarado (o JSON de lançamento do app
oficial é o mesmo do chiaki, com `bravia_tv` / `android`).

FLAGS também não muda nada (sessões das 13:45 às 13:50): com
`availableBits` 0x3f, e com 0x3 e valores 1, 2 e 3 nos bytes 5–8
(`P5M_AUDIO_MASK` / `P5M_AUDIO_FLAGS`), o PS5 aceita a mensagem e segue em
`00 02` com os canais 2–5 mudos. Conclusão provisória: o transporte 5.1
existe, mas o console mistura para estéreo antes de codificar; o que o faz
mandar surround de verdade não está no que o app do Mac envia.

**Ordem dos canais:** ainda não verificada. O P5M usa WAVE
(L R C LFE Ls Rs), mas com pares primeiro o mais provável é L R Ls Rs C LFE.
A medição `[audio-channels] 10s levels` (volume e % de graves por canal)
mostra o LFE (graves perto de 100%) quando os canais tiverem som.

**Leitura do app oficial (08/10, depois dos testes de FLAGS).**

- O número de canais do decodificador vem só do nibble alto do byte de tipo
  do pacote (`AvHeader_20`, lido junto com o codec logo após o cabeçalho).
  Quando ele muda no meio da sessão, o app recria o decodificador ("Reinit
  audio decoder: [%d -> %d] channels") e manda telemetria
  `AudioNumChannelsChange` (`numChannelsOld` / `numChannelsNew`). O
  decodificador é a libopus padrão (`opus_multistream_decoder_create` com
  mapeamento identidade e uma tabela streams/pares por nº de canais).
- O cabeçalho de 2 bytes (`00 02`) não chega à libopus, então é tirado na
  montagem do quadro; não achei onde nem se o app olha o valor.
- Tudo o que o app manda de AUDIOSTATE: FLAGS (`availableBits` 3, valores 0)
  ao receber o STREAMINFO e CHANNELNUM por uma função que aceita a opção
  1–5. Não há HRTF, TVCONFIG nem PORTSTATES enviados, e o app do Mac não tem
  texto de interface para surround; a configuração de cliente dele diz
  `"audioChannels":"2.1"`.

Conclusão: o P5M já manda tudo o que o app oficial manda para pedir
multicanal. O PS5 abre o transporte 5.1, mas a mistura que ele codifica
continua estéreo. Nada indica que o app oficial do Mac receba surround de
verdade. O código fica atrás de `P5M_AUDIO_CHANNELS`: se um dia o console
mandar conteúdo nos canais 2–5, o caminho até o CoreAudio já está pronto.

## Pad info e DualSense (leitura do app oficial, 08/10)

Pacote de pad info (0x19 bytes; 0x1a na v20), a partir de `buf[8]` (no
formato antigo de 0x11/0x12 bytes, a partir de `buf[0]`):

| Byte | Campo | O que o app oficial faz |
|---|---|---|
| +0 | índice do jogador | usa só o nibble baixo |
| +1..3 | RGB da barra | escala pelo brilho e envia |
| +4 | reset de movimento | só age com valor 1 |
| +5 | correção de inclinação | liga/desliga na fusão de movimento |
| +6 | banda morta do giroscópio | idem |
| +7..10 | preset de controle | não se aplica ao DualSense |
| +11 | modo de vibração 1..5 | muda os bits do relatório HID; visto: 1 no Homem-Aranha 2 e 2 fora dele (menu do PS5 ou jogo sem haptics avançados, sem faixa de haptics); significado exato a confirmar |
| +12 | intensidade da vibração | `haptic_vol` |
| +13 | intensidade dos gatilhos | `haptic_vol` |
| +14 | brilho da barra (0/1/2 = 100/50/25%) | escala o RGB |
| +16 | haptics nativo | escolhe entre emulação de rumble e haptics |

Os usos de +0, +1..3, +4, +12 e +13 já eram conhecidos. Os de +5, +6, +11,
+14 e +16 saem da ordem dos campos na estrutura do app, sem leitura direta
do conversor; o P5M registra no diário (`[pad-info]`) quando mudam, para
confirmar. O P5M aplica o brilho (+14), confirmado em sessão (0/1/2 seguem a opção do PS5), e deixa os outros só no diário.

Outros pontos do app oficial que o P5M passou a seguir: mudo do microfone
no bit 4 (0x10) do byte de economia de energia (o 0x08 é a economia do
áudio do controle) e, ao fim da sessão, barra azul e LEDs de jogador e de
mudo apagados.
