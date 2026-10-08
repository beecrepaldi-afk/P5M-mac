# P5M para Mac (branch `mac`)

Fork do chiaki-ng ajustado para macOS em Apple Silicon. A referência é um
MacBook Air M5 (painel de 60 Hz, sem ProMotion) com o DualSense no cabo.

## Compilar

```bash
./mac/compilar.sh
```

As dependências vêm do Homebrew: Qt 6, FFmpeg, SDL2, OpenSSL 3, protobuf 29 e
Ninja. O app sai em `build-mac/gui/chiaki.app`.

## Trazer o registro do PS5 do Quest

O app do Quest exporta um JSON. O chiaki-ng do desktop só importa INI.
`mac/quest2ini.cpp` converte um no outro:

```bash
quest2ini chiaki-settings.json chiaki-ps5.ini
```

Depois importe em Settings → Config → "Import settings from file". A
importação substitui as configurações atuais. O INI contém as chaves do
console, então não deve entrar no repositório. O conversor recusa um destino
que já existe, valida todos os consoles antes de gravar e publica o INI
com permissão de leitura/escrita apenas para o usuário. Entrada inválida
não gera uma configuração parcial.

A regressão do conversor usa somente dados sintéticos:

```bash
python3 test/test_quest2ini.py
```

Regressão HDR (exige uma GPU Metal local; não conecta ao console):

```bash
python3 test/test_p5m_hdr.py
```

## O que muda em relação ao chiaki-ng

### Vídeo: renderizador Metal (`gui/src/metalrenderer.mm`)

- **Leitura direta dos quadros:** o quadro do VideoToolbox é lido pela GPU via
  `CVMetalTextureCache`, sem cópia.
- **Conversão de cor no shader:** YCbCr → RGB, com BT.709, BT.2020 e BT.601,
  faixa limitada ou completa.
- **HDR experimental:** saída em sRGB linear estendido (fp16), com branco
  SDR em 1,0. A interface é linearizada sem curva de tom; só o vídeo PQ
  recebe compressão para a folga EDR atual, consultada a cada segundo.
  Não há metadados HDR10 na camada que contém a interface. Precisa validar
  visualmente menus e transparências com HDR ligado/desligado.
- **HDR com saída SDR:** o PQ é mapeado para SDR com o tone mapper do P5M. O ponto de branco
  do painel fica em 240 nits; acima do joelho a curva comprime suavemente; o
  gamut 2020→709 é trazido para dentro por luminância; e entra um dither
  triangular.
- **MetalFX spatial:** amplia o 1080p para a resolução da tela. O dither vem
  depois da ampliação, para o MetalFX não ampliar o ruído.
- **Interface:** o Qt Quick desenha com o próprio RHI Metal numa textura
  nossa, composta por cima do vídeo.
- **Apresentação:** no máximo 2 quadros esperam a tela, e um quadro mais novo
  substitui o que ainda não foi exibido. O desenho nunca bloqueia esperando a
  tela.
- **Tearing guiado (VSync desligado, recomendado):** sem VSync, a tela troca
  a imagem ~3 ms depois do envio, em vez de esperar a próxima varredura
  inteira. Como o PS5 e o painel rodam a 60 Hz, o corte do tearing ficaria
  parado no mesmo lugar. Para evitar isso:
  - o app lê o ritmo da tela (`CVDisplayLink`);
  - espera a GPU terminar o quadro;
  - numa thread de tempo real, segura o quadro até a troca cair no intervalo
    entre duas varreduras, onde o corte fica fora da imagem;
  - mantém um quadro por varredura, para não engasgar quando os quadros
    chegam bem na fronteira.

  Resultado: ~18–20 ms do quadro à tela, contra ~31 ms com VSync. Em jogo
  normal, 94–99% das trocas caem escondidas. Ainda escapa um corte a cada
  1–2 s, e mais quando o macOS sai do Direct (notificações). Para evitar
  notificações, ligue um Foco por agendamento de app (Ajustes → Foco →
  Adicionar Agendamento → App → chiaki).
- **Tela cheia:** nativa do macOS. O app estica a janela sobre o painel
  inteiro, e o macOS apresenta em **Direct**. A faixa em volta da câmera
  fica preta: o macOS não mostra nada ali em tela cheia nativa.
  - Uma tela cheia sem bordas mostraria a faixa, mas foi testada e
    descartada em 03/10/2026: o compositor volta a entrar (+10 ms) e às vezes
    para de atualizar a imagem.
- **Diário a cada 10 s no log:**
  - `[pacing]`: buracos entre quadros, quadro→tela, GPU e espera pela tela.
  - `[decode]`: tempo de decodificação.
  - `P5M: bitrate`: bitrate pedido e recebido, RTT e perda.

No modo Metal o app não cria contexto OpenGL nem nada do libplacebo. Isso
tira ~80 ms da abertura e ~225 MB de memória. Para voltar ao caminho original
do chiaki-ng (libplacebo), escolha "OpenGL" ou "Vulkan" em Settings →
Renderer. O padrão no Mac é Metal. Nesse modo os presets de imagem e o
diálogo "Placebo" do menu não têm efeito.

| Variável | Efeito |
|---|---|
| `CHIAKI_METALFX=0` | desliga o MetalFX |
| `CHIAKI_METAL_QUEUE=1` | fila de 1 quadro (pior: perde quadros) |
| `CHIAKI_METAL_DISPLAYLINK=1` | pacing por `CAMetalDisplayLink` (cadência perfeita, ~5 ms a mais) |
| `CHIAKI_TEAR_STEER=0` | desliga o tearing guiado (sem VSync, corte livre) |
| `CHIAKI_TEAR_OFFSET_US=n` | desloca a mira da troca em n µs (negativo = mais cedo) |
| `MTL_HUD_ENABLED=1` | HUD da Apple: mostra "Direct" ou "Composited" |

### Interface: tema do P5M e uso com o controle

A interface segue o visual do P5M do Quest: azul PS5, vidro e contorno branco
de foco. As peças reutilizáveis ficam em `gui/src/qml/p5m/` (`Theme`,
`GlassButton`, `StepRow`, `Glyph`, `HintBar`, `PadKeyboard`...). Todo o app
funciona só com o DualSense.

- **Início ("Play"):** categorias à esquerda (Play, Screen, Stream,
  Controller, General) e consoles à direita. Os cards mostram estado em
  linguagem simples (Pronto, Repouso, Não registrado) e os botões que valem
  no card focado.
- **Durante o jogo:**
  - **R1+L3+R3** (padrão, igual ao P5M) ou `⌘O` abre o painel do stream:
    - Tela: modo da imagem, zoom e tela cheia;
    - Som: volume e microfone;
    - Sessão: encerrar;
    - Ao vivo: bitrate, perda e quadros, com bolinha verde, amarela ou
      vermelha.
  - **○** fecha o painel; **segurar ○ por 1 s** encerra a sessão.
- **Configurações:** coluna de categorias navegável pelo D-pad, L1/R1 troca
  de categoria, ○ volta da página para a lista. No modo Metal somem as opções
  do libplacebo, que não têm efeito.
- **Teclado na tela:** com controle conectado, ✕ num campo de texto abre o
  teclado do P5M:
  - ✕ digita;
  - □ apaga;
  - △ alterna maiúsculas;
  - Options conclui.
- **Correções de navegação herdadas do chiaki-ng:**
  - no Mac, o Qt só punha campos de texto na ordem de foco, e os diálogos
    abriam sem nada focado: agora entram todos os controles;
  - os controles compartilhados engoliam o ○, que não voltava;
  - ✕ e ○ não repetem mais quando segurados.

### Rede, vinda dos patches da libchiaki do P5M

- **Buffer de recepção de 1 MB** no socket Takion (era 100 KB). Evita descarte
  nas rajadas de quadro IDR.
- **Marcação do socket:**
  - `SO_NET_SERVICE_TYPE = NET_SERVICE_TYPE_VI`, a classe "vídeo interativo"
    do FaceTime;
  - DSCP AF41.
- **RUDP:** um erro de rede passageiro não derruba mais a conexão remota (PSN).
- **Decodificador:** `AV_CODEC_FLAG_LOW_DELAY`, porque o stream não tem
  B-frames.

### Integração com o macOS

- **Botão PS e Create** chegam ao PS5 em vez de abrir os menus do sistema:
  `preferredSystemGestureState` e as chaves `GCSupportsControllerUserInteraction`
  e `LSSupportsGameMode` no Info.plist.
- **Durante a sessão**, uma atividade do `NSProcessInfo` mantém a tela acesa e
  desliga o App Nap e o agrupamento de timers.
- **QoS user-interactive** para as threads de rede e decodificação, a de
  controle e a de renderização.
- **Vibração:** o dispositivo de áudio de vibração do DualSense é aberto fora
  da thread da interface. Antes, a abertura travava a janela ~1 s no início do
  stream.
- **Trackpad do Mac** livre por padrão. O touchpad do DualSense continua
  funcionando.
- **Atalhos durante a sessão** (o resto do teclado vai para o PS5):
  - `⌘O`: menu da transmissão.
  - `⌃⌘F`: entra e sai da tela cheia. O F11 é do macOS (mostrar mesa).
  - `⌘W`: desconectar (pergunta se o PS5 deve dormir). O botão `×` no topo
    do menu faz o mesmo.
  - `⌘Q`: fecha o app, como em qualquer app do Mac. A sessão é encerrada
    direito com o PS5, sem perguntar.
  - `⌘S`, `⌘Z` e `⌘M`: os mesmos atalhos de `Ctrl` do chiaki-ng.

## Medições (03/10/2026, Air M5, 1080p60, 100 Mbps pedidos)

| Trecho | Tempo |
|---|---|
| Rede | sem perda, 60–80 Mbps recebidos |
| Decodificação (VideoToolbox) | ~5 ms |
| GPU (cor + MetalFX + interface) | ~4–5 ms |
| Quadro decodificado → tela, VSync ligado | ~30 ms |
| Quadro decodificado → tela, VSync desligado (tearing guiado) | ~18–20 ms |
| Quadro decodificado → tela, VSync desligado sem guia | ~8 ms (corte visível) |

Com VSync, o macOS leva dois ciclos de 60 Hz até a tela, mesmo em Direct.
Abaixo dos ~18 ms do tearing guiado, só com tela mais rápida (ProMotion, ou
monitor externo de 120 Hz+ com VRR).

O aviso do Game Overlay do macOS 26 ("aperte o botão… para o painel de
jogo") aparece no começo da sessão e tira a imagem do Direct enquanto está na
tela. Isso causa uma queda curta.

## Pendente

- Vibração e gatilhos do DualSense via Bluetooth (hoje só no cabo).
- Imagem congelando em tela cheia (o macOS para de exibir os quadros, e
  parece que os botões não respondem). Apareceu ao forçar a janela sobre a
  faixa do notch: com reforço por timer, com janela sem bordas e com
  conteúdo sob a barra de título. Esses reforços foram desfeitos em
  03/10/2026. Falta confirmar que, sem eles, não congela mais.
- HDR na folga EDR da tela do Air (2× acima do branco com o brilho abaixo do
  máximo): pedir H.265 HDR e entregar em EDR. Conferir se continua em Direct.
- Interpolação de quadros e super-resolução do VideoToolbox (opcionais).
- Empacotar um `.app` assinado.

## Preparação de distribuição e integração com o sistema

O pacote portátil é criado por `python3 mac/package.py` em `dist/P5M.app`
e `dist/P5M.zip`, sem alterar a build original. A auditoria inclui todas as
bibliotecas e calcula o macOS mínimo real. Nesta máquina as dependências
exigem macOS 27; a assinatura ad-hoc não equivale a Developer ID nem
notarização. Procedimento público em [DISTRIBUTION.md](DISTRIBUTION.md).

O app usa identidade P5M própria e copia configurações legadas somente
quando o destino está vazio, sem apagar a origem. Atalhos expõe acordar e
conectar console, diagnóstico e silenciar microfone. A Siri executa
atalhos nomeados. General › Session diagnostics oferece explicação local
por FoundationModels após a sessão, somente com métricas numéricas.
Nenhuma inferência é iniciada durante o stream. Detalhes e checagens
manuais em [RELEASE.md](RELEASE.md).

`ctest --test-dir build-mac --output-on-failure` reúne as regressões de
HDR/Metal, integração Swift, privacidade, migração e callbacks HID além
dos testes de protocolo. Os testes usam dados sintéticos e não abrem o
app nem conectam ao console.

## Saída nativa de áudio

CoreAudio recebe o PCM por uma fila limitada, consumida pelo callback do
sistema. Estéreo e mono seguem diretos. As opções Spatial audio (padrão
ligado) e Head tracking (padrão desligado) preparam a renderização de PCM
multicanal com ordem conhecida; HDMI capaz recebe PCM multicanal direto.
O protocolo Sony atual não fornece o mapping Opus multistream: o decoder
continua aceitando 1/2 canais, sem inventar surround. Estéreo binaural
recebido é preservado; isso não comprova nem ativa Tempest no console.
Troca de saída, áudio espacial e rastreamento ainda precisam de teste real.
