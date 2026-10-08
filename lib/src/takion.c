// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "chiaki/feedback.h"
#include <chiaki/takion.h>
#include <chiaki/congestioncontrol.h>
#include <chiaki/random.h>
#include <chiaki/gkcrypt.h>
#include <chiaki/time.h>

#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <assert.h>

#ifdef __APPLE__
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#include <CoreServices/CoreServices.h>
#endif
#endif

#ifdef _WIN32
#include <ws2tcpip.h>
#elif defined(__SWITCH__)
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#else
#include <unistd.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <sys/socket.h>
#endif


// VERY similar to SCTP, see RFC 4960

#define TAKION_A_RWND 0x19000
#define TAKION_OUTBOUND_STREAMS 0x64
#define TAKION_INBOUND_STREAMS 0x64

#define TAKION_REORDER_QUEUE_SIZE_EXP 4 // => 16 entries
#define TAKION_AV_VIDEO_REORDER_QUEUE_SIZE_EXP 6 // => 64 entries
#define TAKION_AV_REORDER_TIMEOUT_US 16000 // ~1 frame at 60fps
#define TAKION_SEND_BUFFER_SIZE 16

#define TAKION_POSTPONE_PACKETS_SIZE 32

#define TAKION_MESSAGE_HEADER_SIZE 0x10

#define TAKION_PACKET_BASE_TYPE_MASK 0xf

#define TAKION_EXPECT_TIMEOUT_MS 5000

#define MAX_CONNECT_RESEND_TRIES 3
/**
 * Base type of Takion packets. Lower nibble of the first byte in datagrams.
 */
typedef enum takion_packet_type_t {
	TAKION_PACKET_TYPE_CONTROL = 0,
	TAKION_PACKET_TYPE_FEEDBACK_HISTORY = 1,
	TAKION_PACKET_TYPE_VIDEO = 2,
	TAKION_PACKET_TYPE_AUDIO = 3,
	TAKION_PACKET_TYPE_HANDSHAKE = 4,
	TAKION_PACKET_TYPE_CONGESTION = 5,
	TAKION_PACKET_TYPE_FEEDBACK_STATE = 6,
	TAKION_PACKET_TYPE_CLIENT_INFO = 8,
} TakionPacketType;

/**
 * @return The offset of the mac of size CHIAKI_GKCRYPT_GMAC_SIZE inside a packet of type or -1 if unknown.
 */
int takion_packet_type_mac_offset(TakionPacketType type)
{
	switch(type)
	{
		case TAKION_PACKET_TYPE_CONTROL:
			return 5;
		case TAKION_PACKET_TYPE_VIDEO:
		case TAKION_PACKET_TYPE_AUDIO:
			return 0xa;
		case TAKION_PACKET_TYPE_CONGESTION:
			return 7;
		default:
			return -1;
	}
}

/**
 * @return The offset of the 4-byte key_pos inside a packet of type or -1 if unknown.
 */
int takion_packet_type_key_pos_offset(TakionPacketType type)
{
	switch(type)
	{
		case TAKION_PACKET_TYPE_CONTROL:
			return 0x9;
		case TAKION_PACKET_TYPE_VIDEO:
		case TAKION_PACKET_TYPE_AUDIO:
			return 0xe;
		case TAKION_PACKET_TYPE_CONGESTION:
			return 0xb;
		default:
			return -1;
	}
}

typedef enum takion_chunk_type_t {
	TAKION_CHUNK_TYPE_DATA = 0,
	TAKION_CHUNK_TYPE_INIT = 1,
	TAKION_CHUNK_TYPE_INIT_ACK = 2,
	TAKION_CHUNK_TYPE_DATA_ACK = 3,
	TAKION_CHUNK_TYPE_COOKIE = 0xa,
	TAKION_CHUNK_TYPE_COOKIE_ACK = 0xb,
} TakionChunkType;

typedef struct takion_message_t
{
	uint32_t tag;
	//uint8_t zero[4];
	uint64_t key_pos;

	uint8_t chunk_type;
	uint8_t chunk_flags;
	uint16_t payload_size;
	uint8_t *payload;
} TakionMessage;

typedef struct takion_message_payload_init_t
{
	uint32_t tag;
	uint32_t a_rwnd;
	uint16_t outbound_streams;
	uint16_t inbound_streams;
	uint32_t initial_seq_num;
} TakionMessagePayloadInit;

#define TAKION_COOKIE_SIZE 0x20

typedef struct takion_message_payload_init_ack_t
{
	uint32_t tag;
	uint32_t a_rwnd;
	uint16_t outbound_streams;
	uint16_t inbound_streams;
	uint32_t initial_seq_num;
	uint8_t cookie[TAKION_COOKIE_SIZE];
} TakionMessagePayloadInitAck;

typedef struct
{
	uint8_t *packet_buf;
	size_t packet_size;
	uint8_t type_b;
	uint8_t *payload; // inside packet_buf
	size_t payload_size;
	uint16_t channel;
	uint8_t ext; // extended header size the packet was received with, for re-checking its MAC
} TakionDataPacketEntry;

typedef struct
{
	uint8_t base_type;
	uint8_t *buf;
	size_t buf_size;
	ChiakiTakionAVPacket packet;
} TakionAVPacketEntry;

typedef struct chiaki_takion_postponed_packet_t
{
	uint8_t *buf;
	size_t buf_size;
} ChiakiTakionPostponedPacket;

static void *takion_thread_func(void *user);
static void takion_handle_packet(ChiakiTakion *takion, uint8_t *buf, size_t buf_size);
static ChiakiErrorCode takion_handle_packet_mac(ChiakiTakion *takion, uint8_t base_type, uint8_t *buf, size_t buf_size, size_t ext);
static void takion_handle_packet_message(ChiakiTakion *takion, uint8_t *buf, size_t buf_size, size_t ext);
static void takion_handle_packet_message_data(ChiakiTakion *takion, uint8_t *packet_buf, size_t packet_buf_size, uint8_t ext, uint8_t type_b, uint8_t *payload, size_t payload_size);
static void takion_handle_packet_message_data_ack(ChiakiTakion *takion, uint8_t flags, uint8_t *buf, size_t buf_size);
static ChiakiErrorCode takion_parse_message(ChiakiTakion *takion, uint8_t *buf, size_t buf_size, TakionMessage *msg);
static void takion_write_message_header(uint8_t *buf, uint32_t tag, uint64_t key_pos, uint8_t chunk_type, uint8_t chunk_flags, size_t payload_data_size);
static ChiakiErrorCode takion_send_message_init(ChiakiTakion *takion, TakionMessagePayloadInit *payload);
static ChiakiErrorCode takion_send_message_cookie(ChiakiTakion *takion, uint8_t *cookie);
static ChiakiErrorCode takion_recv(ChiakiTakion *takion, uint8_t *buf, size_t *buf_size, uint64_t timeout_ms);
static ChiakiErrorCode takion_recv_message_init_ack(ChiakiTakion *takion, TakionMessagePayloadInitAck *payload);
static ChiakiErrorCode takion_recv_message_cookie_ack(ChiakiTakion *takion);
static void takion_handle_packet_av(ChiakiTakion *takion, uint8_t base_type, uint8_t *buf, size_t buf_size);
static ChiakiErrorCode takion_read_extra_sock_messages(ChiakiTakion *takion);

CHIAKI_EXPORT ChiakiErrorCode chiaki_takion_connect(ChiakiTakion *takion, ChiakiTakionConnectInfo *info, chiaki_socket_t *sock)
{
	ChiakiErrorCode ret = CHIAKI_ERR_SUCCESS;

	takion->log = info->log;
	takion->close_socket = info->close_socket;
	takion->version = info->protocol_version;
	takion->disable_audio_video = info->disable_audio_video;
	takion->ext_size = 0;
	takion->ext_counter = 0;
	takion->ext_clock_start_us = 0;
	takion->ext_rx_have_prev = false;
	takion->ext_rx_window_start_us = 0;
	takion->ext_rx_count = 0;
	takion->ext_rx_abs_sum_us = 0;
	takion->ext_rx_abs_max_us = 0;

	switch(takion->version)
	{
		case 7:
			takion->av_packet_parse = chiaki_takion_v7_av_packet_parse;
			break;
		case 9:
			takion->av_packet_parse = chiaki_takion_v9_av_packet_parse;
			break;
		case 12:
			takion->av_packet_parse = chiaki_takion_v12_av_packet_parse;
			break;
		default:
			CHIAKI_LOGE(takion->log, "Unknown Takion Protocol Version %u", (unsigned int)takion->version);
			return CHIAKI_ERR_INVALID_DATA;
	}

	takion->gkcrypt_local = NULL;
	ret = chiaki_mutex_init(&takion->gkcrypt_local_mutex, true);
	if(ret != CHIAKI_ERR_SUCCESS)
		return ret;
	takion->key_pos_local = 0;
	takion->gkcrypt_remote = NULL;
	takion->cb = info->cb;
	takion->cb_user = info->cb_user;
	takion->a_rwnd = TAKION_A_RWND;

	takion->tag_local = chiaki_random_32(); // 0x4823
	takion->seq_num_local = takion->tag_local;
	ret = chiaki_mutex_init(&takion->seq_num_local_mutex, false);
	if(ret != CHIAKI_ERR_SUCCESS)
		goto error_gkcrypt_local_mutex;
	takion->tag_remote = 0;

	takion->enable_crypt = info->enable_crypt;
	takion->postponed_packets = NULL;
	takion->postponed_packets_size = 0;
	takion->postponed_packets_count = 0;
	takion->enable_dualsense = info->enable_dualsense;

	CHIAKI_LOGI(takion->log, "Takion connecting (version %u)", (unsigned int)info->protocol_version);
	bool mac_dontfrag = true;

	ChiakiErrorCode err = chiaki_stop_pipe_init(&takion->stop_pipe);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(takion->log, "Takion failed to create stop pipe");
		goto error_seq_num_local_mutex;
	}

	if(sock)
	{
		takion->sock = *sock;
		err = takion_read_extra_sock_messages(takion);
		if(err != CHIAKI_ERR_SUCCESS && err != CHIAKI_ERR_TIMEOUT)
		{
			CHIAKI_LOGE(takion->log, "Takion had problem reading extra messages from socket using PSN Connection with error: " CHIAKI_SOCKET_ERROR_FMT, CHIAKI_SOCKET_ERROR_VALUE);
			goto error_sock;
		}
		const int rcvbuf_val = takion->a_rwnd;
		int r = setsockopt(takion->sock, SOL_SOCKET, SO_RCVBUF, (const CHIAKI_SOCKET_BUF_TYPE)&rcvbuf_val, sizeof(rcvbuf_val));
		if(r < 0)
		{
			CHIAKI_LOGE(takion->log, "Takion failed to setsockopt SO_RCVBUF: " CHIAKI_SOCKET_ERROR_FMT, CHIAKI_SOCKET_ERROR_VALUE);
			ret = CHIAKI_ERR_NETWORK;
			goto error_sock;
		}

#if defined(__APPLE__) && TARGET_OS_OSX
		SInt32 majorVersion;
		Gestalt(gestaltSystemVersionMajor, &majorVersion);
		if(majorVersion < 11)
		{
			mac_dontfrag = false;
		}
#endif
		if(info->ip_dontfrag)
		{
#if defined(_WIN32)
			const DWORD dontfragment_val = 1;
			r = setsockopt(takion->sock, IPPROTO_IP, IP_DONTFRAGMENT, (const CHIAKI_SOCKET_BUF_TYPE)&dontfragment_val, sizeof(dontfragment_val));
#elif defined(__FreeBSD__) || defined(__SWITCH__) || defined(__APPLE__)
			if(mac_dontfrag)
			{
				const int dontfrag_val = 1;
				r = setsockopt(takion->sock, IPPROTO_IP, IP_DONTFRAG, (const CHIAKI_SOCKET_BUF_TYPE)&dontfrag_val, sizeof(dontfrag_val));
			}
			else
				CHIAKI_LOGW(takion->log, "Don't fragment is not supported on this platform, MTU values may be incorrect.");
#elif defined(IP_PMTUDISC_DO)
			const int mtu_discover_val = IP_PMTUDISC_DO;
			r = setsockopt(takion->sock, IPPROTO_IP, IP_MTU_DISCOVER, (const CHIAKI_SOCKET_BUF_TYPE)&mtu_discover_val, sizeof(mtu_discover_val));
#else
			// macOS older than MacOS Big Sur (11) and OpenBSD
			CHIAKI_LOGW(takion->log, "Don't fragment is not supported on this platform, MTU values may be incorrect.");
#define NO_DONTFRAG
#endif

#ifndef NO_DONTFRAG
			if(r < 0 && mac_dontfrag)
			{
				CHIAKI_LOGE(takion->log, "Takion failed to setsockopt IP_MTU_DISCOVER: " CHIAKI_SOCKET_ERROR_FMT, CHIAKI_SOCKET_ERROR_VALUE);
				ret = CHIAKI_ERR_NETWORK;
				goto error_sock;
			}
			CHIAKI_LOGI(takion->log, "Takion enabled Don't Fragment Bit");
#endif
		}
		else
		{
#if defined(_WIN32)
			const DWORD dontfragment_val = 0;
			r = setsockopt(takion->sock, IPPROTO_IP, IP_DONTFRAGMENT, (const CHIAKI_SOCKET_BUF_TYPE)&dontfragment_val, sizeof(dontfragment_val));
#elif defined(__FreeBSD__) || defined(__SWITCH__) || defined(__APPLE__)
			if(mac_dontfrag)
			{
				const int dontfrag_val = 0;
				r = setsockopt(takion->sock, IPPROTO_IP, IP_DONTFRAG, (const CHIAKI_SOCKET_BUF_TYPE)&dontfrag_val, sizeof(dontfrag_val));
			}
#elif defined(IP_PMTUDISC_DO)
			const int mtu_discover_val = IP_PMTUDISC_DONT;
			r = setsockopt(takion->sock, IPPROTO_IP, IP_MTU_DISCOVER, (const CHIAKI_SOCKET_BUF_TYPE)&mtu_discover_val, sizeof(mtu_discover_val));
#else
			// macOS older than MacOS Big Sur (11) and OpenBSD
#define NO_DONTFRAG
#endif

#ifndef NO_DONTFRAG
			if(r < 0 && mac_dontfrag)
			{
				CHIAKI_LOGE(takion->log, "Takion failed to unset setsockopt IP_MTU_DISCOVER: " CHIAKI_SOCKET_ERROR_FMT, CHIAKI_SOCKET_ERROR_VALUE);
				ret = CHIAKI_ERR_NETWORK;
				goto error_sock;
			}
			CHIAKI_LOGI(takion->log, "Takion disabled Don't Fragment Bit");
#endif
		}
	}
	else
	{
		takion->sock = socket(info->sa->sa_family, SOCK_DGRAM, IPPROTO_UDP);
		if(CHIAKI_SOCKET_IS_INVALID(takion->sock))
		{
			CHIAKI_LOGE(takion->log, "Takion failed to create socket");
			ret = CHIAKI_ERR_NETWORK;
			goto error_pipe;
		}
		const int rcvbuf_val = takion->a_rwnd;
		int r = setsockopt(takion->sock, SOL_SOCKET, SO_RCVBUF, (const CHIAKI_SOCKET_BUF_TYPE)&rcvbuf_val, sizeof(rcvbuf_val));
		if(r < 0)
		{
			CHIAKI_LOGE(takion->log, "Takion failed to setsockopt SO_RCVBUF: " CHIAKI_SOCKET_ERROR_FMT, CHIAKI_SOCKET_ERROR_VALUE);
			ret = CHIAKI_ERR_NETWORK;
			goto error_sock;
		}
		if(info->ip_dontfrag)
		{
#if defined(__APPLE__) && TARGET_OS_OSX
			SInt32 majorVersion;
			Gestalt(gestaltSystemVersionMajor, &majorVersion);
			if(majorVersion < 11)
			{
				mac_dontfrag = false;
			}
#endif
#if defined(_WIN32)
			const DWORD dontfragment_val = 1;
			r = setsockopt(takion->sock, IPPROTO_IP, IP_DONTFRAGMENT, (const CHIAKI_SOCKET_BUF_TYPE)&dontfragment_val, sizeof(dontfragment_val));
#elif defined(__FreeBSD__) || defined(__SWITCH__) || defined(__APPLE__)
			const int dontfrag_val = 1;
			r = setsockopt(takion->sock, IPPROTO_IP, IP_DONTFRAG, (const CHIAKI_SOCKET_BUF_TYPE)&dontfrag_val, sizeof(dontfrag_val));
#elif defined(IP_PMTUDISC_DO)
			if(mac_dontfrag)
			{
				const int mtu_discover_val = IP_PMTUDISC_DO;
				r = setsockopt(takion->sock, IPPROTO_IP, IP_MTU_DISCOVER, (const CHIAKI_SOCKET_BUF_TYPE)&mtu_discover_val, sizeof(mtu_discover_val));
			}
			else
				CHIAKI_LOGW(takion->log, "Don't fragment is not supported on this platform, MTU values may be incorrect.");
#else
			// macOS older than MacOS Big Sur (11) and OpenBSD
			CHIAKI_LOGW(takion->log, "Don't fragment is not supported on this platform, MTU values may be incorrect.");
#define NO_DONTFRAG
#endif

#ifndef NO_DONTFRAG
			if(r < 0 && mac_dontfrag)
			{
				CHIAKI_LOGE(takion->log, "Takion failed to setsockopt IP_MTU_DISCOVER: " CHIAKI_SOCKET_ERROR_FMT, CHIAKI_SOCKET_ERROR_VALUE);
				ret = CHIAKI_ERR_NETWORK;
				goto error_sock;
			}
			CHIAKI_LOGI(takion->log, "Takion enabled Don't Fragment Bit");
#endif
		}
		else
		{
#if defined(_WIN32)
			const DWORD dontfragment_val = 0;
			r = setsockopt(takion->sock, IPPROTO_IP, IP_DONTFRAGMENT, (const CHIAKI_SOCKET_BUF_TYPE)&dontfragment_val, sizeof(dontfragment_val));
#elif defined(__FreeBSD__) || defined(__SWITCH__) || defined(__APPLE__)
			if(mac_dontfrag)
			{
				const int dontfrag_val = 0;
				r = setsockopt(takion->sock, IPPROTO_IP, IP_DONTFRAG, (const CHIAKI_SOCKET_BUF_TYPE)&dontfrag_val, sizeof(dontfrag_val));
			}
#elif defined(IP_PMTUDISC_DO)
			const int mtu_discover_val = IP_PMTUDISC_DONT;
			r = setsockopt(takion->sock, IPPROTO_IP, IP_MTU_DISCOVER, (const CHIAKI_SOCKET_BUF_TYPE)&mtu_discover_val, sizeof(mtu_discover_val));
#else
			// macOS older than MacOS Big Sur (11) and OpenBSD
#define NO_DONTFRAG
#endif

#ifndef NO_DONTFRAG
			if(r < 0 && mac_dontfrag)
			{
				CHIAKI_LOGE(takion->log, "Takion failed to unset setsockopt IP_MTU_DISCOVER: " CHIAKI_SOCKET_ERROR_FMT, CHIAKI_SOCKET_ERROR_VALUE);
				ret = CHIAKI_ERR_NETWORK;
				goto error_sock;
			}
			CHIAKI_LOGI(takion->log, "Takion disabled Don't Fragment Bit");
#endif
		}

		r = connect(takion->sock, info->sa, info->sa_len);
		if(r < 0)
		{
			CHIAKI_LOGE(takion->log, "Takion failed to connect: " CHIAKI_SOCKET_ERROR_FMT, CHIAKI_SOCKET_ERROR_VALUE);
			ret = CHIAKI_ERR_NETWORK;
			goto error_sock;
		}
		if(r != CHIAKI_ERR_SUCCESS)
		{
			ret = err;
			goto error_sock;
		}
	}

	// P5M: marcacao de prioridade no socket.
	//
	// O fluxo do Remote Play saia sem marca nenhuma, na mesma fila que todo o
	// resto da rede. Um ponto de acesso com WMM classifica por DSCP, e AF41
	// (34) cai na categoria de video -- a que existe justamente para trafego
	// continuo e sensivel a atraso. Escolhido em vez de EF/voz de proposito:
	// voz tem prioridade maior mas rajada menor, e 25 Mbps de video em rajadas
	// curtas seria trocar atraso por perda.
	//
	// SO_PRIORITY vai junto porque as duas coisas agem em lugares diferentes:
	// o DSCP viaja no pacote e serve ao ponto de acesso, e a prioridade do
	// socket fica no aparelho e ordena a fila local antes de o pacote sair. O
	// valor 5 cai na mesma categoria de video pelo mapeamento 802.1d, e acima
	// de 6 o Android exige capacidade de rede que um app nao tem.
	//
	// As duas sao pedidos, nao garantias: driver e ponto de acesso podem
	// ignorar. Por isso nenhuma falha aqui interrompe a conexao -- so registra.
	//
	// Registrado em WARNING mesmo quando da certo, e nao em INFO. Nao e
	// descuido: o log_cb do Android mapeia WARNING para ANDROID_LOG_ERROR, e o
	// diario do P5M captura Chiaki:E. Em INFO estas linhas existiriam so no
	// buffer circular do logcat, que se perde em minutos -- e sem PC para ler
	// o logcat ao vivo, uma linha que nao chega ao diario nao chega a lugar
	// nenhum.
	{
		// A familia do endereco vem do SOCKET, e nao de info->sa.
		//
		// Isto ja custou um SIGSEGV. Em senkusha.c o ChiakiTakionConnectInfo e
		// uma struct de pilha nao inicializada, e quando ja existe um socket --
		// que e o caso da conexao remota, onde ele chega furado pelo holepunch
		// -- os campos sa e sa_len nunca sao preenchidos. O codigo original so
		// lia info->sa dentro do ramo que os preenche; este bloco roda fora
		// dele, entao ler info->sa->sa_family aqui era desreferenciar lixo de
		// pilha. Localmente passava despercebido, porque ali o campo existe.
		//
		// O socket ja existe nos dois caminhos a esta altura, e ele sabe a
		// propria familia. Se getsockname falhar, IPv4 e o palpite certo: e o
		// unico que o console aceita ("IPV6 NOT supported by your PlayStation
		// console" aparece no proprio log da furacao).
		struct sockaddr_storage endereco_local;
		socklen_t endereco_local_len = sizeof(endereco_local);
		int familia = AF_INET;
		if(getsockname(takion->sock, (struct sockaddr *)&endereco_local,
				&endereco_local_len) == 0)
			familia = endereco_local.ss_family;

#ifdef SO_NET_SERVICE_TYPE
		// macOS: the FaceTime class. The system queues the socket as
		// interactive video and the Wi-Fi driver gives it the video access
		// category; IP_TOS below then pins the DSCP to AF41.
		const int service_type = NET_SERVICE_TYPE_VI;
		if(setsockopt(takion->sock, SOL_SOCKET, SO_NET_SERVICE_TYPE,
				(const CHIAKI_SOCKET_BUF_TYPE)&service_type, sizeof(service_type)) < 0)
			CHIAKI_LOGW(takion->log, "P5M: net service type interactive video refused by the system");
		else
			CHIAKI_LOGI(takion->log, "P5M: socket set to net service type interactive video");
#endif
		const int dscp_af41 = 34 << 2;
		int qr;
		if(familia == AF_INET6)
			qr = setsockopt(takion->sock, IPPROTO_IPV6, IPV6_TCLASS,
					(const CHIAKI_SOCKET_BUF_TYPE)&dscp_af41, sizeof(dscp_af41));
		else
			qr = setsockopt(takion->sock, IPPROTO_IP, IP_TOS,
					(const CHIAKI_SOCKET_BUF_TYPE)&dscp_af41, sizeof(dscp_af41));
		if(qr < 0)
			CHIAKI_LOGW(takion->log, "P5M: DSCP AF41 refused by the system");
		else
			CHIAKI_LOGW(takion->log, "P5M: socket marked DSCP AF41 (video class)");

#ifdef SO_PRIORITY
		const int prio = 5;
		if(setsockopt(takion->sock, SOL_SOCKET, SO_PRIORITY,
				(const CHIAKI_SOCKET_BUF_TYPE)&prio, sizeof(prio)) < 0)
			CHIAKI_LOGW(takion->log, "P5M: SO_PRIORITY refused by the system");
		else
			CHIAKI_LOGW(takion->log, "P5M: local socket queue at priority %d", prio);
#endif

		// P5M: buffer de recepcao maior que o do chiaki.
		//
		// O chiaki pede SO_RCVBUF igual ao a_rwnd que anuncia no protocolo:
		// 0x19000, ou 100 KB. Sao dois numeros com donos diferentes que a
		// biblioteca trata como um so. O a_rwnd e uma promessa feita ao
		// console e nao se mexe nele; o SO_RCVBUF e o balde do kernel aqui
		// dentro, e 100 KB e pequeno demais para o que chega em rajada.
		//
		// A conta: 100 KB a 25 Mbps sao 32 ms. Um quadro-chave de 1080p a
		// esse bitrate passa facil de 200 KB e chega todo de uma vez. Se a
		// thread que le o socket estiver fora do processador por um instante
		// -- e num headset ela disputa com composicao, decodificador e o
		// nosso proprio shader -- o kernel descarta o excedente sem avisar
		// ninguem. Do lado de fora a rede esta impecavel: o pacote chegou na
		// antena, foi perdido dentro do aparelho.
		//
		// Isso fecha um circulo que o diario mostrava e eu tinha lido ao
		// contrario: falha de FEC -> pedido de IDR -> quadro-chave grande em
		// rajada -> estouro do balde -> falha de FEC. As 132 falhas
		// concentradas justamente na janela de jogo, com 21 pedidos de IDR no
		// meio, sao a assinatura disso, e nao de uma rede ruim.
		//
		// 1 MB da folga de ~320 ms na mesma conta. O kernel pode conceder
		// menos (o teto e net.core.rmem_max e nao ha como forca-lo sem
		// capacidade de rede), por isso o valor concedido e lido de volta e
		// registrado: se vier abaixo do pedido, esta escrito no diario.
		{
			const int wanted = 1024 * 1024;
			if(setsockopt(takion->sock, SOL_SOCKET, SO_RCVBUF,
					(const CHIAKI_SOCKET_BUF_TYPE)&wanted, sizeof(wanted)) < 0)
				CHIAKI_LOGW(takion->log, "P5M: 1 MB SO_RCVBUF refused; carrying on with chiaki's");
			else
			{
				int granted = 0;
				socklen_t granted_size = sizeof(granted);
				if(getsockopt(takion->sock, SOL_SOCKET, SO_RCVBUF,
						(CHIAKI_SOCKET_BUF_TYPE)&granted, &granted_size) == 0)
					CHIAKI_LOGW(takion->log, "P5M: receive buffer asked %d B, granted %d B "
							"(the kernel usually doubles what was asked)", wanted, granted);
				else
					CHIAKI_LOGW(takion->log, "P5M: receive buffer asked %d B, grant unreadable", wanted);
			}
		}
	}

	err = chiaki_thread_create(&takion->thread, takion_thread_func, takion);

	chiaki_thread_set_name(&takion->thread, "Chiaki Takion");

	return CHIAKI_ERR_SUCCESS;

error_sock:
	if(!CHIAKI_SOCKET_IS_INVALID(takion->sock))
	{
		CHIAKI_SOCKET_CLOSE(takion->sock);
		takion->sock = CHIAKI_INVALID_SOCKET;
	}
error_pipe:
	chiaki_stop_pipe_fini(&takion->stop_pipe);
error_seq_num_local_mutex:
	chiaki_mutex_fini(&takion->seq_num_local_mutex);
error_gkcrypt_local_mutex:
	chiaki_mutex_fini(&takion->gkcrypt_local_mutex);
	return ret;
}

CHIAKI_EXPORT void chiaki_takion_close(ChiakiTakion *takion)
{
	chiaki_stop_pipe_stop(&takion->stop_pipe);
	chiaki_thread_join(&takion->thread, NULL);
	chiaki_stop_pipe_fini(&takion->stop_pipe);
	chiaki_mutex_fini(&takion->seq_num_local_mutex);
	chiaki_mutex_fini(&takion->gkcrypt_local_mutex);
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_takion_crypt_advance_key_pos(ChiakiTakion *takion, size_t data_size, uint64_t *key_pos)
{
	data_size += data_size % CHIAKI_GKCRYPT_BLOCK_SIZE;
	ChiakiErrorCode err = chiaki_mutex_lock(&takion->gkcrypt_local_mutex);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;

	if(takion->gkcrypt_local)
	{
		uint64_t cur = takion->key_pos_local;
		if(SIZE_MAX - cur < data_size)
		{
			chiaki_mutex_unlock(&takion->gkcrypt_local_mutex);
			return CHIAKI_ERR_OVERFLOW;
		}

		*key_pos = cur;
		takion->key_pos_local = cur + data_size;
	}
	else
		*key_pos = 0;

	chiaki_mutex_unlock(&takion->gkcrypt_local_mutex);
	return CHIAKI_ERR_SUCCESS;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_takion_send_raw(ChiakiTakion *takion, const uint8_t *buf, size_t buf_size)
{
	int r = send(takion->sock, buf, buf_size, 0);
	if(r < 0)
	{
		CHIAKI_LOGE(takion->log, "Takion failed to send raw: " CHIAKI_SOCKET_ERROR_FMT, CHIAKI_SOCKET_ERROR_VALUE);
		return CHIAKI_ERR_NETWORK;
	}
	return CHIAKI_ERR_SUCCESS;
}

static ChiakiErrorCode chiaki_takion_packet_read_key_pos(ChiakiTakion *takion, uint8_t *buf, size_t buf_size, size_t ext, uint64_t *key_pos_out)
{
	if(buf_size < 1)
		return CHIAKI_ERR_BUF_TOO_SMALL;

	TakionPacketType base_type = buf[0] & TAKION_PACKET_BASE_TYPE_MASK;
	int key_pos_offset = takion_packet_type_key_pos_offset(base_type);
	if(key_pos_offset < 0)
		return CHIAKI_ERR_INVALID_DATA;
	key_pos_offset += (int)ext;

	if(buf_size < key_pos_offset + sizeof(uint32_t))
		return CHIAKI_ERR_BUF_TOO_SMALL;

	uint32_t key_pos_low = ntohl(*((chiaki_unaligned_uint32_t *)(buf + key_pos_offset)));
	*key_pos_out = chiaki_key_state_request_pos(&takion->key_state, key_pos_low, false);

	return CHIAKI_ERR_SUCCESS;
}

/**
 * Size of the v20 extended header for a packet of this base type.
 * Chunk-based packets (control, handshake, client info) never carry it, only the
 * AV, feedback, congestion and newer packet types do.
 */
static size_t takion_ext_for_type(ChiakiTakion *takion, uint8_t base_type)
{
	switch(base_type)
	{
		case TAKION_PACKET_TYPE_CONTROL:
		case TAKION_PACKET_TYPE_HANDSHAKE:
		case TAKION_PACKET_TYPE_CLIENT_INFO:
			return 0;
		default:
			return takion->ext_size;
	}
}

static ChiakiErrorCode takion_packet_mac_ext(ChiakiGKCrypt *crypt, uint8_t *buf, size_t buf_size, size_t ext, uint64_t key_pos, uint8_t *mac_out, uint8_t *mac_old_out);
static ChiakiErrorCode takion_send_ext(ChiakiTakion *takion, uint8_t *buf, size_t buf_size, size_t ext, uint64_t key_pos);

CHIAKI_EXPORT ChiakiErrorCode chiaki_takion_packet_mac(ChiakiGKCrypt *crypt, uint8_t *buf, size_t buf_size, uint64_t key_pos, uint8_t *mac_out, uint8_t *mac_old_out)
{
	return takion_packet_mac_ext(crypt, buf, buf_size, 0, key_pos, mac_out, mac_old_out);
}

/*
 * P5M: Takion v20 extended header.
 *
 * From v20 on, every packet carries 8 bytes right after the type byte: the
 * sender's send time in microseconds (u32 BE, from a clock started when the
 * version was switched) and a running packet counter (u32 BE). Everything
 * after it, MAC and key_pos included, moves by 8. The header is filled just
 * before the MAC, which covers it. The receiver uses consecutive send times
 * to see the one-way delay growing before packets get lost.
 */
static void takion_ext_header_write(ChiakiTakion *takion, uint8_t *buf)
{
	// call with gkcrypt_local_mutex held
	uint32_t send_us = (uint32_t)(chiaki_time_now_monotonic_us() - takion->ext_clock_start_us);
	*((chiaki_unaligned_uint32_t *)(buf + 1)) = htonl(send_us);
	*((chiaki_unaligned_uint32_t *)(buf + 5)) = htonl(takion->ext_counter++);
}

// Takion thread only. One diary line every ten seconds with the delay variation the console's send times show.
static void takion_ext_header_read(ChiakiTakion *takion, const uint8_t *buf, size_t buf_size)
{
	if(buf_size < 1 + CHIAKI_TAKION_EXT_HEADER_SIZE)
		return;
	uint64_t now_us = chiaki_time_now_monotonic_us();
	uint32_t remote_us = ntohl(*((chiaki_unaligned_uint32_t *)(buf + 1)));
	if(takion->ext_rx_have_prev)
	{
		int64_t local_delta = (int64_t)(now_us - takion->ext_rx_prev_local_us);
		int64_t remote_delta = (int32_t)(remote_us - takion->ext_rx_prev_remote_us);
		int64_t variation = local_delta - remote_delta;
		uint64_t abs_variation = (uint64_t)(variation < 0 ? -variation : variation);
		takion->ext_rx_abs_sum_us += abs_variation;
		if(abs_variation > takion->ext_rx_abs_max_us)
			takion->ext_rx_abs_max_us = abs_variation > UINT32_MAX ? UINT32_MAX : (uint32_t)abs_variation;
		takion->ext_rx_count++;
	}
	else
		takion->ext_rx_window_start_us = now_us;
	takion->ext_rx_have_prev = true;
	takion->ext_rx_prev_local_us = now_us;
	takion->ext_rx_prev_remote_us = remote_us;

	if(now_us - takion->ext_rx_window_start_us >= 10000000 && takion->ext_rx_count > 0)
	{
		CHIAKI_LOGI(takion->log, "[takion-v20] 10s: %llu packets, one-way delay variation avg %llu us, max %u us",
				(unsigned long long)takion->ext_rx_count,
				(unsigned long long)(takion->ext_rx_abs_sum_us / takion->ext_rx_count),
				takion->ext_rx_abs_max_us);
		takion->ext_rx_window_start_us = now_us;
		takion->ext_rx_count = 0;
		takion->ext_rx_abs_sum_us = 0;
		takion->ext_rx_abs_max_us = 0;
	}
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_takion_set_version(ChiakiTakion *takion, uint8_t version)
{
	switch(version)
	{
		case 12:
			takion->av_packet_parse = chiaki_takion_v12_av_packet_parse;
			break;
		case 20:
			takion->av_packet_parse = chiaki_takion_v20_av_packet_parse;
			break;
		default:
			CHIAKI_LOGE(takion->log, "Takion can't switch to protocol version %u", (unsigned int)version);
			return CHIAKI_ERR_INVALID_DATA;
	}
	chiaki_mutex_lock(&takion->gkcrypt_local_mutex);
	takion->ext_clock_start_us = chiaki_time_now_monotonic_us();
	takion->ext_counter = 0;
	takion->ext_rx_have_prev = false;
	takion->version = version;
	takion->ext_size = version >= 20 ? CHIAKI_TAKION_EXT_HEADER_SIZE : 0;
	chiaki_mutex_unlock(&takion->gkcrypt_local_mutex);
	CHIAKI_LOGI(takion->log, "Takion switched to protocol version %u%s", (unsigned int)version,
			takion->ext_size ? " with extended header" : "");
	return CHIAKI_ERR_SUCCESS;
}

static ChiakiErrorCode takion_packet_mac_ext(ChiakiGKCrypt *crypt, uint8_t *buf, size_t buf_size, size_t ext, uint64_t key_pos, uint8_t *mac_out, uint8_t *mac_old_out)
{
	if(buf_size < 1)
		return CHIAKI_ERR_BUF_TOO_SMALL;

	TakionPacketType base_type = buf[0] & TAKION_PACKET_BASE_TYPE_MASK;
	int mac_offset = takion_packet_type_mac_offset(base_type);
	int key_pos_offset = takion_packet_type_key_pos_offset(base_type);
	if(mac_offset < 0 || key_pos_offset < 0)
		return CHIAKI_ERR_INVALID_DATA;
	mac_offset += (int)ext;
	key_pos_offset += (int)ext;

	if(buf_size < mac_offset + CHIAKI_GKCRYPT_GMAC_SIZE || buf_size < key_pos_offset + sizeof(uint32_t))
		return CHIAKI_ERR_BUF_TOO_SMALL;

	if(mac_old_out)
		memcpy(mac_old_out, buf + mac_offset, CHIAKI_GKCRYPT_GMAC_SIZE);

	memset(buf + mac_offset, 0, CHIAKI_GKCRYPT_GMAC_SIZE);

	if(crypt)
	{
		uint8_t key_pos_tmp[sizeof(uint32_t)];
		if(base_type == TAKION_PACKET_TYPE_CONTROL || base_type == TAKION_PACKET_TYPE_CONGESTION)
		{
			memcpy(key_pos_tmp, buf + key_pos_offset, sizeof(uint32_t));
			memset(buf + key_pos_offset, 0, sizeof(uint32_t));
		}
		ChiakiErrorCode err = chiaki_gkcrypt_gmac(crypt, key_pos, buf, buf_size, buf + mac_offset);
		if(err != CHIAKI_ERR_SUCCESS)
			return err;
		if(base_type == TAKION_PACKET_TYPE_CONTROL || base_type == TAKION_PACKET_TYPE_CONGESTION)
			memcpy(buf + key_pos_offset, key_pos_tmp, sizeof(uint32_t));
	}

	if(mac_out)
		memcpy(mac_out, buf + mac_offset, CHIAKI_GKCRYPT_GMAC_SIZE);

	return CHIAKI_ERR_SUCCESS;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_takion_send(ChiakiTakion *takion, uint8_t *buf, size_t buf_size, uint64_t key_pos)
{
	return takion_send_ext(takion, buf, buf_size, 0, key_pos);
}

/**
 * Like chiaki_takion_send, for a packet built with ext bytes reserved after the type byte.
 * ext is the caller's snapshot of takion->ext_size, so a version switch can't change the layout mid-packet.
 */
static ChiakiErrorCode takion_send_ext(ChiakiTakion *takion, uint8_t *buf, size_t buf_size, size_t ext, uint64_t key_pos)
{
	ChiakiErrorCode err = chiaki_mutex_lock(&takion->gkcrypt_local_mutex);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;
	uint8_t mac[CHIAKI_GKCRYPT_GMAC_SIZE];
	if(ext)
		takion_ext_header_write(takion, buf);
	err = takion_packet_mac_ext(takion->gkcrypt_local, buf, buf_size, ext, key_pos, mac, NULL);
	chiaki_mutex_unlock(&takion->gkcrypt_local_mutex);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;

	//CHIAKI_LOGD(takion->log, "Takion sending:");
	//chiaki_log_hexdump(takion->log, CHIAKI_LOG_DEBUG, buf, buf_size);

	return chiaki_takion_send_raw(takion, buf, buf_size);
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_takion_send_message_data(ChiakiTakion *takion, uint8_t chunk_flags, uint16_t channel, uint8_t *buf, size_t buf_size, ChiakiSeqNum32 *seq_num)
{
	// TODO: can we make this more memory-efficient?
	// TODO: split packet if necessary?

	uint64_t key_pos;
	ChiakiErrorCode err = chiaki_takion_crypt_advance_key_pos(takion, buf_size, &key_pos);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;

	size_t ext = takion_ext_for_type(takion, TAKION_PACKET_TYPE_CONTROL);
	size_t packet_size = 1 + ext + TAKION_MESSAGE_HEADER_SIZE + 9 + buf_size;
	uint8_t *packet_buf = malloc(packet_size);
	if(!packet_buf)
		return CHIAKI_ERR_MEMORY;
	packet_buf[0] = TAKION_PACKET_TYPE_CONTROL;

	takion_write_message_header(packet_buf + 1 + ext, takion->tag_remote, key_pos, TAKION_CHUNK_TYPE_DATA, chunk_flags, 9 + buf_size);

	uint8_t *msg_payload = packet_buf + 1 + ext + TAKION_MESSAGE_HEADER_SIZE;

	err = chiaki_mutex_lock(&takion->seq_num_local_mutex);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;
	ChiakiSeqNum32 seq_num_val = takion->seq_num_local++;
	chiaki_mutex_unlock(&takion->seq_num_local_mutex);

	*((chiaki_unaligned_uint32_t *)(msg_payload + 0)) = htonl(seq_num_val);
	*((chiaki_unaligned_uint16_t *)(msg_payload + 4)) = htons(channel);
	*((chiaki_unaligned_uint16_t *)(msg_payload + 6)) = 0;
	*(msg_payload + 8) = 0;
	memcpy(msg_payload + 9, buf, buf_size);

	err = takion_send_ext(takion, packet_buf, packet_size, ext, key_pos); // will alter packet_buf with gmac
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(takion->log, "Takion failed to send data packet: %s", chiaki_error_string(err));
		free(packet_buf);
		return err;
	}

	chiaki_takion_send_buffer_push(&takion->send_buffer, seq_num_val, packet_buf, packet_size);

	if(seq_num)
		*seq_num = seq_num_val;

	return err;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_takion_send_message_data_cont(ChiakiTakion *takion, uint8_t chunk_flags, uint16_t channel, uint8_t *buf, size_t buf_size, ChiakiSeqNum32 *seq_num)
{
	// TODO: can we make this more memory-efficient?
	// TODO: split packet if necessary?

	uint64_t key_pos;
	ChiakiErrorCode err = chiaki_takion_crypt_advance_key_pos(takion, buf_size, &key_pos);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;

	size_t ext = takion_ext_for_type(takion, TAKION_PACKET_TYPE_CONTROL);
	size_t packet_size = 1 + ext + TAKION_MESSAGE_HEADER_SIZE + 8 + buf_size;
	uint8_t *packet_buf = malloc(packet_size);
	if(!packet_buf)
		return CHIAKI_ERR_MEMORY;
	packet_buf[0] = TAKION_PACKET_TYPE_CONTROL;

	takion_write_message_header(packet_buf + 1 + ext, takion->tag_remote, key_pos, TAKION_CHUNK_TYPE_DATA, chunk_flags, 8 + buf_size);

	uint8_t *msg_payload = packet_buf + 1 + ext + TAKION_MESSAGE_HEADER_SIZE;

	err = chiaki_mutex_lock(&takion->seq_num_local_mutex);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;
	ChiakiSeqNum32 seq_num_val = takion->seq_num_local++;
	chiaki_mutex_unlock(&takion->seq_num_local_mutex);

	*((chiaki_unaligned_uint32_t *)(msg_payload + 0)) = htonl(seq_num_val);
	*((chiaki_unaligned_uint16_t *)(msg_payload + 4)) = htons(channel);
	*((chiaki_unaligned_uint16_t *)(msg_payload + 6)) = 0;
	memcpy(msg_payload + 8, buf, buf_size);

	err = takion_send_ext(takion, packet_buf, packet_size, ext, key_pos); // will alter packet_buf with gmac
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(takion->log, "Takion failed to send data packet: %s", chiaki_error_string(err));
		free(packet_buf);
		return err;
	}

	chiaki_takion_send_buffer_push(&takion->send_buffer, seq_num_val, packet_buf, packet_size);

	if(seq_num)
		*seq_num = seq_num_val;

	return err;
}

static ChiakiErrorCode chiaki_takion_send_message_data_ack(ChiakiTakion *takion, uint32_t seq_num)
{
	uint8_t buf[1 + CHIAKI_TAKION_EXT_HEADER_SIZE + TAKION_MESSAGE_HEADER_SIZE + 0xc];
	size_t ext = takion_ext_for_type(takion, TAKION_PACKET_TYPE_CONTROL);
	size_t buf_size = 1 + ext + TAKION_MESSAGE_HEADER_SIZE + 0xc;
	buf[0] = TAKION_PACKET_TYPE_CONTROL;

	uint64_t key_pos;
	ChiakiErrorCode err = chiaki_takion_crypt_advance_key_pos(takion, 1 + TAKION_MESSAGE_HEADER_SIZE + 0xc, &key_pos);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;

	takion_write_message_header(buf + 1 + ext, takion->tag_remote, key_pos, TAKION_CHUNK_TYPE_DATA_ACK, 0, 0xc);

	uint8_t *data_ack = buf + 1 + ext + TAKION_MESSAGE_HEADER_SIZE;
	*((chiaki_unaligned_uint32_t *)(data_ack + 0)) = htonl(seq_num);
	*((chiaki_unaligned_uint32_t *)(data_ack + 4)) = htonl(takion->a_rwnd);
	*((chiaki_unaligned_uint16_t *)(data_ack + 8)) = 0;
	*((chiaki_unaligned_uint16_t *)(data_ack + 0xa)) = 0;

	return takion_send_ext(takion, buf, buf_size, ext, key_pos);
}

CHIAKI_EXPORT void chiaki_takion_format_congestion(uint8_t *buf, ChiakiTakionCongestionPacket *packet, uint64_t key_pos)
{
	buf[0] = TAKION_PACKET_TYPE_CONGESTION;
	*((chiaki_unaligned_uint16_t *)(buf + 1)) = htons(packet->word_0);
	*((chiaki_unaligned_uint16_t *)(buf + 3)) = htons(packet->received);
	*((chiaki_unaligned_uint16_t *)(buf + 5)) = htons(packet->lost);
	*((chiaki_unaligned_uint32_t *)(buf + 7)) = 0;
	*((chiaki_unaligned_uint32_t *)(buf + 0xb)) = htonl((uint32_t)key_pos);
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_takion_send_congestion(ChiakiTakion *takion, ChiakiTakionCongestionPacket *packet)
{
	uint64_t key_pos;
	ChiakiErrorCode err = chiaki_takion_crypt_advance_key_pos(takion, CHIAKI_TAKION_CONGESTION_PACKET_SIZE, &key_pos);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;

	uint8_t buf[CHIAKI_TAKION_EXT_HEADER_SIZE + CHIAKI_TAKION_CONGESTION_PACKET_SIZE];
	size_t ext = takion->ext_size;
	if(ext)
	{
		// v20: same fields, 8 bytes later
		uint8_t plain[CHIAKI_TAKION_CONGESTION_PACKET_SIZE];
		chiaki_takion_format_congestion(plain, packet, key_pos);
		buf[0] = plain[0];
		memcpy(buf + 1 + ext, plain + 1, sizeof(plain) - 1);
	}
	else
		chiaki_takion_format_congestion(buf, packet, key_pos);
	return takion_send_ext(takion, buf, CHIAKI_TAKION_CONGESTION_PACKET_SIZE + ext, ext, key_pos);
}

/**
 * buf: type, ext bytes (v20), seq (2), 0, key_pos (4), gmac (4), payload.
 */
static ChiakiErrorCode takion_send_feedback_packet(ChiakiTakion *takion, uint8_t *buf, size_t buf_size, size_t ext)
{
	assert(buf_size >= 0xc + ext);

	size_t payload_size = buf_size - 0xc - ext;

	ChiakiErrorCode err = chiaki_mutex_lock(&takion->gkcrypt_local_mutex);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;

	uint64_t key_pos;
	err = chiaki_takion_crypt_advance_key_pos(takion, payload_size + CHIAKI_GKCRYPT_BLOCK_SIZE, &key_pos);
	if(err != CHIAKI_ERR_SUCCESS)
		goto beach;

	err = chiaki_gkcrypt_encrypt(takion->gkcrypt_local, key_pos + CHIAKI_GKCRYPT_BLOCK_SIZE, buf + 0xc + ext, payload_size);
	if(err != CHIAKI_ERR_SUCCESS)
		goto beach;

	*((chiaki_unaligned_uint32_t *)(buf + 4 + ext)) = htonl((uint32_t)key_pos);
	if(ext)
		takion_ext_header_write(takion, buf);

	err = chiaki_gkcrypt_gmac(takion->gkcrypt_local, key_pos, buf, buf_size, buf + 8 + ext);
	if(err != CHIAKI_ERR_SUCCESS)
		goto beach;

	chiaki_takion_send_raw(takion, buf, buf_size);

beach:
	chiaki_mutex_unlock(&takion->gkcrypt_local_mutex);
	return err;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_takion_send_feedback_state(ChiakiTakion *takion, ChiakiSeqNum16 seq_num, ChiakiFeedbackState *feedback_state)
{
	uint8_t buf[0xc + CHIAKI_TAKION_EXT_HEADER_SIZE + CHIAKI_FEEDBACK_STATE_BUF_SIZE_MAX];
	size_t ext = takion->ext_size;
	buf[0] = TAKION_PACKET_TYPE_FEEDBACK_STATE;
	memset(buf + 1, 0, ext);
	*((chiaki_unaligned_uint16_t *)(buf + 1 + ext)) = htons(seq_num);
	buf[3 + ext] = 0; // TODO
	*((chiaki_unaligned_uint32_t *)(buf + 4 + ext)) = 0; // key pos
	*((chiaki_unaligned_uint32_t *)(buf + 8 + ext)) = 0; // gmac
	size_t buf_sz;
	if(takion->version <= 9)
	{
		buf_sz = 0xc + ext + CHIAKI_FEEDBACK_STATE_BUF_SIZE_V9;
		chiaki_feedback_state_format_v9(buf + 0xc + ext, feedback_state);
	}
	else
	{
		// v12 and v20 use the same 28 byte state
		buf_sz = 0xc + ext + CHIAKI_FEEDBACK_STATE_BUF_SIZE_V12;
		chiaki_feedback_state_format_v12(buf + 0xc + ext, feedback_state);
	}
	return takion_send_feedback_packet(takion, buf, buf_sz, ext);
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_takion_send_mic_packet(ChiakiTakion *takion, uint8_t *buf, size_t buf_size, bool ps5)
{
	uint8_t ps5_packet = 0;
	if(ps5)
		ps5_packet = 1;
	size_t payload_size = buf_size - 19 - ps5_packet;

	// The audio sender builds the v12 layout; v20 needs the extended header after the type byte.
	size_t ext = takion->ext_size;
	uint8_t *ext_buf = NULL;
	if(ext)
	{
		ext_buf = malloc(buf_size + ext);
		if(!ext_buf)
			return CHIAKI_ERR_MEMORY;
		ext_buf[0] = buf[0];
		memset(ext_buf + 1, 0, ext);
		memcpy(ext_buf + 1 + ext, buf + 1, buf_size - 1);
		buf = ext_buf;
		buf_size += ext;
	}

	ChiakiErrorCode err = chiaki_mutex_lock(&takion->gkcrypt_local_mutex);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		free(ext_buf);
		return err;
	}
	uint64_t key_pos;
	err = chiaki_takion_crypt_advance_key_pos(takion, payload_size + CHIAKI_GKCRYPT_BLOCK_SIZE, &key_pos);
	if(err != CHIAKI_ERR_SUCCESS)
		goto beach;

	err = chiaki_gkcrypt_encrypt(takion->gkcrypt_local, key_pos + CHIAKI_GKCRYPT_BLOCK_SIZE, buf + 19 + ext + ps5_packet, payload_size);
	if(err != CHIAKI_ERR_SUCCESS)
		goto beach;

	*((chiaki_unaligned_uint32_t *)(buf + 14 + ext)) = htonl((uint32_t)key_pos);
	if(ext)
		takion_ext_header_write(takion, buf);

	err = chiaki_gkcrypt_gmac(takion->gkcrypt_local, key_pos, buf, buf_size, buf + 10 + ext);

	if(err != CHIAKI_ERR_SUCCESS)
		goto beach;

	chiaki_takion_send_raw(takion, buf, buf_size);
beach:
	chiaki_mutex_unlock(&takion->gkcrypt_local_mutex);
	free(ext_buf);
	return err;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_takion_send_feedback_history(ChiakiTakion *takion, ChiakiSeqNum16 seq_num, uint8_t *payload, size_t payload_size)
{
	size_t ext = takion->ext_size;
	size_t buf_size = 0xc + ext + payload_size;
	uint8_t *buf = malloc(buf_size);
	if(!buf)
		return CHIAKI_ERR_MEMORY;
	buf[0] = TAKION_PACKET_TYPE_FEEDBACK_HISTORY;
	memset(buf + 1, 0, ext);
	*((chiaki_unaligned_uint16_t *)(buf + 1 + ext)) = htons(seq_num);
	buf[3 + ext] = 0; // TODO
	*((chiaki_unaligned_uint32_t *)(buf + 4 + ext)) = 0; // key pos
	*((chiaki_unaligned_uint32_t *)(buf + 8 + ext)) = 0; // gmac
	memcpy(buf + 0xc + ext, payload, payload_size);
	ChiakiErrorCode err = takion_send_feedback_packet(takion, buf, buf_size, ext);
	free(buf);
	return err;
}

static ChiakiErrorCode takion_handshake(ChiakiTakion *takion, uint32_t *seq_num_remote_initial)
{
	ChiakiErrorCode err;

	// INIT ->

	TakionMessagePayloadInit init_payload;
	init_payload.tag = takion->tag_local;
	init_payload.a_rwnd = TAKION_A_RWND;
	init_payload.outbound_streams = TAKION_OUTBOUND_STREAMS;
	init_payload.inbound_streams = TAKION_INBOUND_STREAMS;
	init_payload.initial_seq_num = takion->seq_num_local;
	int tries = 0;
	TakionMessagePayloadInitAck init_ack_payload;
	for(; tries < MAX_CONNECT_RESEND_TRIES; tries++)
	{
		if(tries > 0)
			CHIAKI_LOGW(takion->log, "Takion hasn't received init ack yet, retrying init [attempt %d] ...", tries + 1);
		memset(&init_ack_payload, 0, sizeof(TakionMessagePayloadInitAck));
		err = takion_send_message_init(takion, &init_payload);
		if(err != CHIAKI_ERR_SUCCESS)
		{
			CHIAKI_LOGE(takion->log, "Takion failed to send init");
			return err;
		}

		CHIAKI_LOGI(takion->log, "Takion sent init");

		// INIT_ACK <-
		err = takion_recv_message_init_ack(takion, &init_ack_payload);
		if(err == CHIAKI_ERR_SUCCESS)
			break;
	}
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(takion->log, "Takion failed to receive init ack");
		return err;
	}

	if(init_ack_payload.tag == 0)
	{
		CHIAKI_LOGE(takion->log, "Takion remote tag in init ack is 0");
		return CHIAKI_ERR_INVALID_RESPONSE;
	}

	CHIAKI_LOGI(takion->log, "Takion received init ack with remote tag %#x, outbound streams: %#x, inbound streams: %#x",
		init_ack_payload.tag, init_ack_payload.outbound_streams, init_ack_payload.inbound_streams);

	takion->tag_remote = init_ack_payload.tag;
	*seq_num_remote_initial = takion->tag_remote; //init_ack_payload.initial_seq_num;

	if(init_ack_payload.outbound_streams == 0 || init_ack_payload.inbound_streams == 0 || init_ack_payload.outbound_streams > TAKION_INBOUND_STREAMS || init_ack_payload.inbound_streams < TAKION_OUTBOUND_STREAMS)
	{
		CHIAKI_LOGE(takion->log, "Takion min/max check failed");
		return CHIAKI_ERR_INVALID_RESPONSE;
	}

	// COOKIE ->
	tries = 0;
	for(; tries < MAX_CONNECT_RESEND_TRIES; tries++)
	{
		if(tries > 0)
			CHIAKI_LOGW(takion->log, "Takion hasn't received cookie ack yet, resending cookie [attempt %d] ...", tries + 1);
		err = takion_send_message_cookie(takion, init_ack_payload.cookie);
		if(err != CHIAKI_ERR_SUCCESS)
		{
			CHIAKI_LOGE(takion->log, "Takion failed to send cookie");
			return err;
		}

		CHIAKI_LOGI(takion->log, "Takion sent cookie");


		// COOKIE_ACK <-

		err = takion_recv_message_cookie_ack(takion);
		if(err == CHIAKI_ERR_SUCCESS)
			break;
	}
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(takion->log, "Takion failed to receive cookie ack");
		return err;
	}

	CHIAKI_LOGI(takion->log, "Takion received cookie ack");


	// done!

	CHIAKI_LOGI(takion->log, "Takion connected");

	return CHIAKI_ERR_SUCCESS;
}

static void takion_data_drop(uint64_t seq_num, void *elem_user, void *cb_user)
{
	ChiakiTakion *takion = cb_user;
	CHIAKI_LOGE(takion->log, "Takion dropping data with seq num %#llx", (unsigned long long)seq_num);
	TakionDataPacketEntry *entry = elem_user;
	free(entry->packet_buf);
	free(entry);
}

static void takion_av_drop(uint64_t seq_num, void *elem_user, void *cb_user)
{
	ChiakiTakion *takion = cb_user;
	CHIAKI_LOGD(takion->log, "Takion dropping AV packet with index %#llx", (unsigned long long)seq_num);
	TakionAVPacketEntry *entry = elem_user;
	free(entry->buf);
	free(entry);
}

/**
 * Pull and dispatch all in-order entries from the given AV queue.
 * If the head packet is missing, wait up to TAKION_AV_REORDER_TIMEOUT_US before
 * skipping it, then retry. This handles WiFi jitter without stalling on lost packets.
 */
// P5M diary: packets held behind a missing one, by outcome. One line / 10 s.
static struct {
	int64_t window_start_us;
	uint64_t late_sum_us, late_max_us, skip_sum_us;
	unsigned late, skips, fec_skips;
} p5m_reorder;

// Unidades AV entregues no quadro atual. O total esperado até last_unit menos
// received conta perdas source e FEC; skips por timeout entram naturalmente.
static unsigned p5m_frame_erasures(const ChiakiTakion *takion)
{
	const unsigned expected = (unsigned)takion->p5m_fec_last_unit + 1;
	return takion->p5m_fec_received <= expected ? expected - takion->p5m_fec_received : UINT32_MAX;
}

static void p5m_note_delivered(ChiakiTakion *takion, const ChiakiTakionAVPacket *packet)
{
	if(!packet->is_video)
		return;
	if(!takion->p5m_fec_frame_valid || packet->frame_index != takion->p5m_fec_frame_index)
	{
		takion->p5m_fec_frame_valid = true;
		takion->p5m_fec_frame_index = packet->frame_index;
		takion->p5m_fec_received = 0;
	}
	takion->p5m_fec_last_unit = packet->unit_index;
	takion->p5m_fec_units_total = packet->units_in_frame_total;
	takion->p5m_fec_units_fec = packet->units_in_frame_fec;
	takion->p5m_fec_received++;
}

// Pula cedo apenas se a lacuna couber no orçamento FEC deste quadro e os
// índices de unidade confirmarem quantos pacotes foram realmente perdidos.
static bool p5m_fec_covers_gap(ChiakiTakion *takion, ChiakiReorderQueue *queue, uint64_t missing)
{
	uint64_t seq_num;
	void *user;
	if(!takion->p5m_fec_frame_valid || missing == 0 || !chiaki_reorder_queue_peek(queue, missing, &seq_num, &user))
		return false;
	const ChiakiTakionAVPacket *next = &((TakionAVPacketEntry *)user)->packet;
	if(!next->is_video)
		return false;
	const unsigned erased = p5m_frame_erasures(takion);
	if(erased == UINT32_MAX)
		return false;
	if(next->frame_index == takion->p5m_fec_frame_index)
	{
		if(next->units_in_frame_total != takion->p5m_fec_units_total
				|| next->units_in_frame_fec != takion->p5m_fec_units_fec
				|| next->unit_index <= takion->p5m_fec_last_unit
				|| (uint64_t)next->unit_index - takion->p5m_fec_last_unit - 1 != missing)
			return false;
		return (uint64_t)erased + missing <= takion->p5m_fec_units_fec;
	}
	if(next->frame_index != (ChiakiSeqNum16)(takion->p5m_fec_frame_index + 1))
		return false;
	const unsigned source_count = takion->p5m_fec_units_total > takion->p5m_fec_units_fec
		? takion->p5m_fec_units_total - takion->p5m_fec_units_fec : 0;
	if(takion->p5m_fec_received < source_count || erased > takion->p5m_fec_units_fec)
		return false;
	const unsigned tail = takion->p5m_fec_units_total > (unsigned)takion->p5m_fec_last_unit + 1
		? takion->p5m_fec_units_total - (unsigned)takion->p5m_fec_last_unit - 1 : 0;
	if((uint64_t)tail + next->unit_index != missing || next->unit_index > next->units_in_frame_fec)
		return false;
	return (uint64_t)erased + tail <= takion->p5m_fec_units_fec;
}

static void p5m_reorder_log(ChiakiTakion *takion, int64_t now)
{
	if(!p5m_reorder.window_start_us)
		p5m_reorder.window_start_us = now;
	if(now - p5m_reorder.window_start_us < 10000000)
		return;
	if(p5m_reorder.late || p5m_reorder.skips || p5m_reorder.fec_skips)
		CHIAKI_LOGI(takion->log, "[reorder] 10s: waited for a late packet %u times (avg %.2f max %.1f ms), "
				"gave up on a lost one %u times (%.1f ms held in total), went on at once (FEC fills it) %u times",
				p5m_reorder.late, p5m_reorder.late ? p5m_reorder.late_sum_us / 1000.0 / p5m_reorder.late : 0.0,
				p5m_reorder.late_max_us / 1000.0, p5m_reorder.skips, p5m_reorder.skip_sum_us / 1000.0, p5m_reorder.fec_skips);
	memset(&p5m_reorder, 0, sizeof(p5m_reorder));
	p5m_reorder.window_start_us = now;
}

static void takion_av_queue_flush_with_timeout(ChiakiTakion *takion, ChiakiReorderQueue *queue,
		int64_t *head_wait_start_us, uint64_t *head_wait_seq_num)
{
	int64_t now = chiaki_time_now_monotonic_us();
	p5m_reorder_log(takion, now);
	bool made_progress = true;

	while(made_progress)
	{
		made_progress = false;

		uint64_t seq_num;
		TakionAVPacketEntry *entry;
		while(chiaki_reorder_queue_pull(queue, &seq_num, (void **)&entry))
		{
			made_progress = true;
			p5m_note_delivered(takion, &entry->packet);
			if(takion->cb)
			{
				ChiakiTakionEvent event = { 0 };
				event.type = CHIAKI_TAKION_EVENT_TYPE_AV;
				event.av = &entry->packet;
				takion->cb(&event, takion->cb_user);
			}
			free(entry->buf);
			free(entry);
		}

		if(made_progress)
		{
			if(*head_wait_start_us != 0)
			{
				const uint64_t waited = (uint64_t)(now - *head_wait_start_us);
				p5m_reorder.late++;
				p5m_reorder.late_sum_us += waited;
				if(waited > p5m_reorder.late_max_us)
					p5m_reorder.late_max_us = waited;
			}
			*head_wait_start_us = 0;
		}

		if(chiaki_reorder_queue_count(queue) == 0)
			break;

		if(*head_wait_start_us != 0 && queue->begin != *head_wait_seq_num)
		{
			if(queue->seq_num_gt(queue->begin, *head_wait_seq_num))
			{
				// The missing head advanced within the same loss burst. Keep the
				// original timeout budget but track the new missing sequence.
				*head_wait_seq_num = queue->begin;
			}
			else
			{
				// A genuinely new gap appeared; start a fresh timeout window.
				*head_wait_start_us = now;
				*head_wait_seq_num = queue->begin;
				break;
			}
		}

		uint64_t missing = 0;
		while(missing < queue->count)
		{
			uint64_t seq_num_peek;
			void *entry_user;
			if(chiaki_reorder_queue_peek(queue, missing, &seq_num_peek, &entry_user))
				break;
			missing++;
		}
		const bool fec_covers = missing < queue->count && p5m_fec_covers_gap(takion, queue, missing);

		// Head slot is missing (packet lost or not yet arrived)
		if(*head_wait_start_us == 0)
		{
			*head_wait_start_us = now;
			*head_wait_seq_num = queue->begin;
			if(!fec_covers)
				break;
		}
		if(!fec_covers && now - *head_wait_start_us <= TAKION_AV_REORDER_TIMEOUT_US)
			break;

		if(fec_covers)
			p5m_reorder.fec_skips++;
		else
		{
			p5m_reorder.skips++;
			p5m_reorder.skip_sum_us += (uint64_t)(now - *head_wait_start_us);
		}
		// Timeout exceeded: skip directly to the first buffered packet so startup
		// and burst reordering only pay a single timeout.
		uint64_t skipped = 0;
		while(skipped < queue->count)
		{
			uint64_t seq_num_peek;
			void *entry_user;
			if(chiaki_reorder_queue_peek(queue, skipped, &seq_num_peek, &entry_user))
				break;
			skipped++;
		}
		if(skipped >= queue->count)
			break;

		CHIAKI_LOGD(takion->log, "Takion AV reorder timeout: skipping %llu missing packet(s) before %#llx",
			(unsigned long long)skipped,
			(unsigned long long)queue->seq_num_add(queue->begin, skipped));
		queue->begin = queue->seq_num_add(queue->begin, skipped);
		queue->count -= skipped;
		*head_wait_start_us = 0;
		made_progress = true;
	}
}

static void takion_av_queues_flush_with_timeout(ChiakiTakion *takion)
{
	if(takion->video_queue_initialized)
	{
		takion_av_queue_flush_with_timeout(takion, &takion->video_queue,
			&takion->video_queue_head_wait_start_us, &takion->video_queue_head_wait_seq_num);
	}
}

static uint64_t takion_av_queues_next_timeout_ms(ChiakiTakion *takion)
{
	int64_t now = chiaki_time_now_monotonic_us();
	uint64_t timeout_ms = UINT64_MAX;
	int64_t *head_waits[] = {
		&takion->video_queue_head_wait_start_us,
	};

	for(size_t i=0; i<sizeof(head_waits) / sizeof(head_waits[0]); i++)
	{
		int64_t head_wait_start_us = *head_waits[i];
		if(head_wait_start_us == 0)
			continue;

		int64_t remaining_us = TAKION_AV_REORDER_TIMEOUT_US - (now - head_wait_start_us);
		if(remaining_us <= 0)
			return 0;

		uint64_t candidate_timeout_ms = (uint64_t)((remaining_us + 999) / 1000);
		if(candidate_timeout_ms < timeout_ms)
			timeout_ms = candidate_timeout_ms;
	}

	return timeout_ms;
}

static void *takion_thread_func(void *user)
{
	ChiakiTakion *takion = user;
	chiaki_thread_set_affinity(CHIAKI_THREAD_NAME_TAKION);

	takion->video_queue_initialized = false;
	takion->video_queue_head_wait_start_us = 0;
	takion->video_queue_head_wait_seq_num = 0;
	takion->p5m_fec_frame_valid = false;
	takion->p5m_fec_frame_index = 0;
	takion->p5m_fec_last_unit = 0;
	takion->p5m_fec_units_total = 0;
	takion->p5m_fec_units_fec = 0;
	takion->p5m_fec_received = 0;

	uint32_t seq_num_remote_initial;
	if(takion_handshake(takion, &seq_num_remote_initial) != CHIAKI_ERR_SUCCESS)
		goto beach;

	if(chiaki_reorder_queue_init_32(&takion->data_queue, TAKION_REORDER_QUEUE_SIZE_EXP, seq_num_remote_initial) != CHIAKI_ERR_SUCCESS)
		goto beach;

	chiaki_reorder_queue_set_drop_cb(&takion->data_queue, takion_data_drop, takion);

	// The send buffer size MUST be consistent with the acked seqnums array size in takion_handle_packet_message_data_ack()
	if(chiaki_takion_send_buffer_init(&takion->send_buffer, takion, TAKION_SEND_BUFFER_SIZE) != CHIAKI_ERR_SUCCESS)
		goto error_reoder_queue;


	if(takion->cb)
	{
		ChiakiTakionEvent event = { 0 };
		event.type = CHIAKI_TAKION_EVENT_TYPE_CONNECTED;
		takion->cb(&event, takion->cb_user);
	}

	bool crypt_available = takion->gkcrypt_remote ? true : false;

	while(true)
	{
		if(takion->enable_crypt && !crypt_available && takion->gkcrypt_remote)
		{
			crypt_available = true;
			CHIAKI_LOGI(takion->log, "Crypt has become available. Re-checking MACs of %llu packets", (unsigned long long)chiaki_reorder_queue_count(&takion->data_queue));
			for(uint64_t i=0; i<chiaki_reorder_queue_count(&takion->data_queue); i++)
			{
				TakionDataPacketEntry *packet;
				bool peeked = chiaki_reorder_queue_peek(&takion->data_queue, i, NULL, (void **)&packet);
				if(!peeked)
					continue;
				if(packet->packet_size == 0)
					continue;
				uint8_t base_type = (uint8_t)(packet->packet_buf[0] & TAKION_PACKET_BASE_TYPE_MASK);
				if(takion_handle_packet_mac(takion, base_type, packet->packet_buf, packet->packet_size, packet->ext) != CHIAKI_ERR_SUCCESS)
				{
					CHIAKI_LOGW(takion->log, "Found an invalid MAC");
					chiaki_reorder_queue_drop(&takion->data_queue, i);
				}
			}

		}

		if(takion->postponed_packets && takion->gkcrypt_remote)
		{
			// there are some postponed packets that were waiting until crypt is initialized and it is now :-)

			CHIAKI_LOGI(takion->log, "Takion flushing %llu postpone packet(s)", (unsigned long long)takion->postponed_packets_count);

			for(size_t i=0; i<takion->postponed_packets_count; i++)
			{
				ChiakiTakionPostponedPacket *packet = &takion->postponed_packets[i];
				takion_handle_packet(takion, packet->buf, packet->buf_size);
			}
			free(takion->postponed_packets);
			takion->postponed_packets = NULL;
			takion->postponed_packets_size = 0;
			takion->postponed_packets_count = 0;
		}

		size_t received_size = 1500;
		uint8_t *buf = malloc(received_size); // TODO: no malloc?
		if(!buf)
			break;
		uint64_t recv_timeout_ms = takion_av_queues_next_timeout_ms(takion);
		if(recv_timeout_ms == 0)
		{
			free(buf);
			takion_av_queues_flush_with_timeout(takion);
			continue;
		}
		ChiakiErrorCode err = takion_recv(takion, buf, &received_size, recv_timeout_ms);
		if(err != CHIAKI_ERR_SUCCESS)
		{
			free(buf);
			if(err == CHIAKI_ERR_TIMEOUT)
			{
				takion_av_queues_flush_with_timeout(takion);
				continue;
			}
			break;
		}
		uint8_t *resized_buf = realloc(buf, received_size);
		if(!resized_buf)
		{
			free(buf);
			continue;
		}
		takion_handle_packet(takion, resized_buf, received_size);
	}

	chiaki_takion_send_buffer_fini(&takion->send_buffer);

	if(takion->video_queue_initialized)
	{
		chiaki_reorder_queue_fini(&takion->video_queue);
		takion->video_queue_initialized = false;
	}

error_reoder_queue:
	chiaki_reorder_queue_fini(&takion->data_queue);

beach:
	if(takion->cb)
	{
		ChiakiTakionEvent event = { 0 };
		event.type = CHIAKI_TAKION_EVENT_TYPE_DISCONNECT;
		takion->cb(&event, takion->cb_user);
	}
	if(takion->close_socket)
	{
		if(!CHIAKI_SOCKET_IS_INVALID(takion->sock))
		{
			CHIAKI_SOCKET_CLOSE(takion->sock);
			takion->sock = CHIAKI_INVALID_SOCKET;
		}
	}
	return NULL;
}

// P5M diary of the raw arrival, in kernel time (the moment each datagram
// reached the socket, SO_TIMESTAMP_MONOTONIC): how a video frame's packets
// are spread, at what rate they come, the pauses between frames, and how
// late our thread picks them up. One line every 10 s.
static uint64_t p5m_rx_us;     // kernel arrival of the packet being handled
static struct {
	uint64_t window_start_us;
	int32_t frame;
	uint64_t first_us, last_us, bytes;
	unsigned pkts;
	unsigned frames, rate_n;
	uint64_t span_sum_us, span_max_us;
	double rate_sum;
	unsigned gap_hist[8];      // inside a frame: <.05 <.1 <.25 <.5 <1 <2 <4 >=4 ms
	uint64_t gap_max_us;
	uint64_t inter_sum_us, inter_max_us;
	unsigned inter_n;
	uint64_t wake_sum_us, wake_max_us;
	unsigned wake_n;
} p5m_pk = { .frame = -1 };

#ifdef __APPLE__
#include <mach/mach_time.h>
static uint64_t p5m_mach_to_us(uint64_t t)
{
	static mach_timebase_info_data_t tb;
	if(!tb.denom)
		mach_timebase_info(&tb);
	return t * tb.numer / tb.denom / 1000;
}
#endif

static void p5m_packets_note_video(ChiakiTakion *takion, ChiakiSeqNum16 frame_index, size_t size)
{
	const uint64_t t = p5m_rx_us;
	if(!t)
		return;
	if(p5m_pk.frame != frame_index)
	{
		if(p5m_pk.frame >= 0)
		{
			const uint64_t span = p5m_pk.last_us - p5m_pk.first_us;
			p5m_pk.frames++;
			p5m_pk.span_sum_us += span;
			if(span > p5m_pk.span_max_us)
				p5m_pk.span_max_us = span;
			if(p5m_pk.pkts >= 4 && span > 0)
			{
				p5m_pk.rate_sum += p5m_pk.bytes * 8.0 / span; // Mbit/s
				p5m_pk.rate_n++;
			}
			if(t > p5m_pk.last_us)
			{
				const uint64_t inter = t - p5m_pk.last_us;
				p5m_pk.inter_sum_us += inter;
				p5m_pk.inter_n++;
				if(inter > p5m_pk.inter_max_us)
					p5m_pk.inter_max_us = inter;
			}
		}
		p5m_pk.frame = frame_index;
		p5m_pk.first_us = p5m_pk.last_us = t;
		p5m_pk.bytes = 0;
		p5m_pk.pkts = 0;
	}
	else if(t >= p5m_pk.last_us)
	{
		const uint64_t gap = t - p5m_pk.last_us;
		static const uint64_t edges[7] = { 50, 100, 250, 500, 1000, 2000, 4000 };
		unsigned bin = 0;
		while(bin < 7 && gap >= edges[bin])
			bin++;
		p5m_pk.gap_hist[bin]++;
		if(gap > p5m_pk.gap_max_us)
			p5m_pk.gap_max_us = gap;
		p5m_pk.last_us = t;
	}
	p5m_pk.bytes += size;
	p5m_pk.pkts++;

	if(!p5m_pk.window_start_us)
		p5m_pk.window_start_us = t;
	if(t - p5m_pk.window_start_us >= 10000000 && p5m_pk.frames)
	{
		const unsigned *h = p5m_pk.gap_hist;
		CHIAKI_LOGI(takion->log, "[packets] 10s (kernel time): %u frames, span avg %.2f max %.1f ms, rate inside a frame %.1f Mbps; "
				"gaps inside a frame <.05ms %u, <.1 %u, <.25 %u, <.5 %u, <1 %u, <2 %u, <4 %u, more %u (max %.1f ms); "
				"between frames avg %.2f max %.1f ms; picked up after avg %.3f max %.2f ms",
				p5m_pk.frames, p5m_pk.span_sum_us / 1000.0 / p5m_pk.frames, p5m_pk.span_max_us / 1000.0,
				p5m_pk.rate_n ? p5m_pk.rate_sum / p5m_pk.rate_n : 0.0,
				h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], p5m_pk.gap_max_us / 1000.0,
				p5m_pk.inter_n ? p5m_pk.inter_sum_us / 1000.0 / p5m_pk.inter_n : 0.0, p5m_pk.inter_max_us / 1000.0,
				p5m_pk.wake_n ? p5m_pk.wake_sum_us / 1000.0 / p5m_pk.wake_n : 0.0, p5m_pk.wake_max_us / 1000.0);
		const int32_t frame = p5m_pk.frame;
		const uint64_t first = p5m_pk.first_us, last = p5m_pk.last_us, bytes = p5m_pk.bytes;
		const unsigned pkts = p5m_pk.pkts;
		memset(&p5m_pk, 0, sizeof(p5m_pk));
		p5m_pk.frame = frame;
		p5m_pk.first_us = first;
		p5m_pk.last_us = last;
		p5m_pk.bytes = bytes;
		p5m_pk.pkts = pkts;
		p5m_pk.window_start_us = t;
	}
}

static ChiakiErrorCode takion_recv(ChiakiTakion *takion, uint8_t *buf, size_t *buf_size, uint64_t timeout_ms)
{
	ChiakiErrorCode err = chiaki_stop_pipe_select_single(&takion->stop_pipe, takion->sock, false, timeout_ms);
	if(err == CHIAKI_ERR_TIMEOUT || err == CHIAKI_ERR_CANCELED)
		return err;
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(takion->log, "Takion select failed: " CHIAKI_SOCKET_ERROR_FMT, CHIAKI_SOCKET_ERROR_VALUE);
		return err;
	}

#ifdef __APPLE__
	// Per takion and socket: the Senkusha takion runs first and the stream's
	// socket often gets the same number afterwards.
	static chiaki_socket_t ts_sock = CHIAKI_INVALID_SOCKET;
	static ChiakiTakion *ts_takion = NULL;
	if(ts_sock != takion->sock || ts_takion != takion)
	{
		ts_takion = takion;
		int on = 1;
		if(setsockopt(takion->sock, SOL_SOCKET, SO_TIMESTAMP_MONOTONIC, &on, sizeof(on)) != 0)
			CHIAKI_LOGW(takion->log, "P5M: kernel arrival timestamps unavailable");
		ts_sock = takion->sock;
	}
	struct iovec iov = { .iov_base = buf, .iov_len = *buf_size };
	union { struct cmsghdr align; uint8_t data[CMSG_SPACE(sizeof(uint64_t)) + 64]; } control;
	struct msghdr msg = { 0 };
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = control.data;
	msg.msg_controllen = sizeof(control.data);
	CHIAKI_SSIZET_TYPE received_sz = recvmsg(takion->sock, &msg, 0);
	p5m_rx_us = 0;
	if(received_sz > 0)
	{
		const uint64_t now_mach = mach_absolute_time();
		for(struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c))
		{
			if(c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_TIMESTAMP_MONOTONIC)
			{
				uint64_t kernel_mach;
				memcpy(&kernel_mach, CMSG_DATA(c), sizeof(kernel_mach));
				p5m_rx_us = p5m_mach_to_us(kernel_mach);
				if(now_mach >= kernel_mach)
				{
					const uint64_t wake = p5m_mach_to_us(now_mach - kernel_mach);
					p5m_pk.wake_sum_us += wake;
					p5m_pk.wake_n++;
					if(wake > p5m_pk.wake_max_us)
						p5m_pk.wake_max_us = wake;
				}
			}
		}
	}
#else
	CHIAKI_SSIZET_TYPE received_sz = recv(takion->sock, buf, *buf_size, 0);
#endif
	if(received_sz <= 0)
	{
		if(received_sz < 0)
			CHIAKI_LOGE(takion->log, "Takion recv failed: " CHIAKI_SOCKET_ERROR_FMT, CHIAKI_SOCKET_ERROR_VALUE);
		else
			CHIAKI_LOGE(takion->log, "Takion recv returned 0");
		return CHIAKI_ERR_NETWORK;
	}
	*buf_size = (size_t)received_sz;
	return CHIAKI_ERR_SUCCESS;
}

static ChiakiErrorCode takion_handle_packet_mac(ChiakiTakion *takion, uint8_t base_type, uint8_t *buf, size_t buf_size, size_t ext)
{
	if(!takion->gkcrypt_remote)
		return CHIAKI_ERR_SUCCESS;

	uint8_t mac[CHIAKI_GKCRYPT_GMAC_SIZE];
	uint8_t mac_expected[CHIAKI_GKCRYPT_GMAC_SIZE];
	uint64_t key_pos;
	ChiakiErrorCode err = chiaki_takion_packet_read_key_pos(takion, buf, buf_size, ext, &key_pos);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(takion->log, "Takion failed to pull key_pos out of received packet");
		return err;
	}
	err = takion_packet_mac_ext(takion->gkcrypt_remote, buf, buf_size, ext, key_pos, mac_expected, mac);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(takion->log, "Takion failed to calculate mac for received packet");
		return err;
	}

	if(memcmp(mac_expected, mac, sizeof(mac)) != 0)
	{
		CHIAKI_LOGE(takion->log, "Takion packet MAC mismatch for packet type %#x with key_pos %#llx", base_type, key_pos);
		chiaki_log_hexdump(takion->log, CHIAKI_LOG_ERROR, buf, buf_size);
		CHIAKI_LOGV(takion->log, "GMAC:");
		chiaki_log_hexdump(takion->log, CHIAKI_LOG_DEBUG, mac, sizeof(mac));
		CHIAKI_LOGV(takion->log, "GMAC expected:");
		chiaki_log_hexdump(takion->log, CHIAKI_LOG_DEBUG, mac_expected, sizeof(mac_expected));
		return CHIAKI_ERR_INVALID_MAC;
	}

	chiaki_key_state_commit(&takion->key_state, key_pos);

	return CHIAKI_ERR_SUCCESS;
}

static void takion_postpone_packet(ChiakiTakion *takion, uint8_t *buf, size_t buf_size)
{
	if(!takion->postponed_packets)
	{
		takion->postponed_packets = calloc(TAKION_POSTPONE_PACKETS_SIZE, sizeof(ChiakiTakionPostponedPacket));
		if(!takion->postponed_packets)
			return;
		takion->postponed_packets_size = TAKION_POSTPONE_PACKETS_SIZE;
		takion->postponed_packets_count = 0;
	}

	if(takion->postponed_packets_count >= takion->postponed_packets_size)
	{
		CHIAKI_LOGE(takion->log, "Should postpone a packet, but there is no space left");
		return;
	}

	CHIAKI_LOGI(takion->log, "Postpone packet of size %#llx", (unsigned long long)buf_size);
	ChiakiTakionPostponedPacket *packet = &takion->postponed_packets[takion->postponed_packets_count++];
	packet->buf = buf;
	packet->buf_size = buf_size;
}

/**
 * @param buf ownership of this buf is taken.
 */
static void takion_handle_packet(ChiakiTakion *takion, uint8_t *buf, size_t buf_size)
{
	assert(buf_size > 0);
	uint8_t base_type = (uint8_t)(buf[0] & TAKION_PACKET_BASE_TYPE_MASK);
	size_t ext = takion_ext_for_type(takion, base_type);
	if(buf_size < 1 + ext)
	{
		free(buf);
		return;
	}

	if(takion_handle_packet_mac(takion, base_type, buf, buf_size, ext) != CHIAKI_ERR_SUCCESS)
	{
		free(buf);
		return;
	}

	if(ext)
		takion_ext_header_read(takion, buf, buf_size);

	switch(base_type)
	{
		case TAKION_PACKET_TYPE_CONTROL:
			takion_handle_packet_message(takion, buf, buf_size, ext);
			break;
		case TAKION_PACKET_TYPE_VIDEO:
		case TAKION_PACKET_TYPE_AUDIO:
			if(takion->enable_crypt && !takion->gkcrypt_remote)
				takion_postpone_packet(takion, buf, buf_size);
			else
				takion_handle_packet_av(takion, base_type, buf, buf_size);
			break;
		default:
			CHIAKI_LOGW(takion->log, "Takion packet with unknown type %#x received", base_type);
			chiaki_log_hexdump(takion->log, CHIAKI_LOG_WARNING, buf, buf_size);
			free(buf);
			break;
	}
}


static void takion_handle_packet_message(ChiakiTakion *takion, uint8_t *buf, size_t buf_size, size_t ext)
{
	TakionMessage msg;
	ChiakiErrorCode err = takion_parse_message(takion, buf + 1 + ext, buf_size - 1 - ext, &msg);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		free(buf);
		return;
	}

	//CHIAKI_LOGD(takion->log, "Takion received message with tag %#x, key pos %#x, type (%#x, %#x), payload size %#x, payload:", msg.tag, msg.key_pos, msg.type_a, msg.type_b, msg.payload_size);
	//chiaki_log_hexdump(takion->log, CHIAKI_LOG_DEBUG, buf, buf_size);

	switch(msg.chunk_type)
	{
		case TAKION_CHUNK_TYPE_DATA:
			takion_handle_packet_message_data(takion, buf, buf_size, (uint8_t)ext, msg.chunk_flags, msg.payload, msg.payload_size);
			break;
		case TAKION_CHUNK_TYPE_DATA_ACK:
			takion_handle_packet_message_data_ack(takion, msg.chunk_flags, msg.payload, msg.payload_size);
			free(buf);
			break;
		default:
			CHIAKI_LOGW(takion->log, "Takion received message with unknown chunk type = %#x", msg.chunk_type);
			free(buf);
			break;
	}
}

static void takion_flush_data_queue(ChiakiTakion *takion)
{
	uint64_t seq_num = 0;
	bool ack = false;
	while(true)
	{
		TakionDataPacketEntry *entry;
		bool pulled = chiaki_reorder_queue_pull(&takion->data_queue, &seq_num, (void **)&entry);
		if(!pulled)
			break;
		ack = true;

		if(entry->payload_size < 9)
		{
			free(entry->packet_buf);
			free(entry);
			continue;
		}

		uint16_t zero_a = *((chiaki_unaligned_uint16_t *)(entry->payload + 6));
		uint8_t data_type = entry->payload[8]; // & 0xf

		if(zero_a != 0)
			CHIAKI_LOGW(takion->log, "Takion received data with unexpected nonzero %#x at buf+6", zero_a);

		if(data_type != CHIAKI_TAKION_MESSAGE_DATA_TYPE_PROTOBUF
				&& data_type != CHIAKI_TAKION_MESSAGE_DATA_TYPE_RUMBLE
				&& data_type != CHIAKI_TAKION_MESSAGE_DATA_TYPE_TRIGGER_EFFECTS
				&& data_type != CHIAKI_TAKION_MESSAGE_DATA_TYPE_PAD_INFO)
		{
			CHIAKI_LOGW(takion->log, "Takion received data with unexpected data type %#x", data_type);
			chiaki_log_hexdump(takion->log, CHIAKI_LOG_WARNING, entry->packet_buf, entry->packet_size);
		}
		else if(takion->cb)
		{
			ChiakiTakionEvent event = { 0 };
			event.type = CHIAKI_TAKION_EVENT_TYPE_DATA;
			event.data.data_type = (ChiakiTakionMessageDataType)data_type;
			event.data.buf = entry->payload + 9;
			event.data.buf_size = (size_t)(entry->payload_size - 9);
			takion->cb(&event, takion->cb_user);
		}

		free(entry->packet_buf);
		free(entry);
	}

	if(ack)
		chiaki_takion_send_message_data_ack(takion, (uint32_t)seq_num);
}

static void takion_handle_packet_message_data(ChiakiTakion *takion, uint8_t *packet_buf, size_t packet_buf_size, uint8_t ext, uint8_t type_b, uint8_t *payload, size_t payload_size)
{
	if(type_b != 1)
		CHIAKI_LOGW(takion->log, "Takion received data with type_b = %#x (was expecting %#x)", type_b, 1);

	if(payload_size < 9)
	{
		CHIAKI_LOGE(takion->log, "Takion received data with a size less than the header size");
		return;
	}

	TakionDataPacketEntry *entry = malloc(sizeof(TakionDataPacketEntry));
	if(!entry)
		return;

	entry->type_b = type_b;
	entry->packet_buf = packet_buf;
	entry->packet_size = packet_buf_size;
	entry->ext = ext;
	entry->payload = payload;
	entry->payload_size = payload_size;
	entry->channel = ntohs(*((chiaki_unaligned_uint16_t *)(payload + 4)));
	ChiakiSeqNum32 seq_num = ntohl(*((chiaki_unaligned_uint32_t *)(payload + 0)));

	chiaki_reorder_queue_push(&takion->data_queue, seq_num, entry);
	takion_flush_data_queue(takion);
}

static void takion_handle_packet_message_data_ack(ChiakiTakion *takion, uint8_t flags, uint8_t *buf, size_t buf_size)
{
	if(buf_size != 0xc)
	{
		CHIAKI_LOGE(takion->log, "Takion received data ack with size %zx != %#x", buf_size, 0xc);
		return;
	}

	uint32_t cumulative_seq_num = ntohl(*((chiaki_unaligned_uint32_t *)(buf + 0)));
	uint32_t a_rwnd = ntohl(*((chiaki_unaligned_uint32_t *)(buf + 4)));
	uint16_t gap_ack_blocks_count = ntohs(*((chiaki_unaligned_uint16_t *)(buf + 8)));
	uint16_t dup_tsns_count = ntohs(*((chiaki_unaligned_uint16_t *)(buf + 0xa)));

	if(buf_size != gap_ack_blocks_count * 4 + 0xc)
	{
		CHIAKI_LOGW(takion->log, "Takion received data ack with invalid gap_ack_blocks_count");
		return;
	}

	if(dup_tsns_count != 0)
		CHIAKI_LOGW(takion->log, "Takion received data ack with nonzero dup_tsns_count %#x", dup_tsns_count);

	CHIAKI_LOGV(takion->log, "Takion received data ack with cumulative_seq_num = %#x, a_rwnd = %#x, gap_ack_blocks_count = %#x, dup_tsns_count = %#x",
			cumulative_seq_num, a_rwnd, gap_ack_blocks_count, dup_tsns_count);

	ChiakiSeqNum32 acked_seq_nums[TAKION_SEND_BUFFER_SIZE];
	size_t acked_seq_nums_count = 0;
	chiaki_takion_send_buffer_ack(&takion->send_buffer, cumulative_seq_num, acked_seq_nums, &acked_seq_nums_count);

	for(size_t i=0; i<acked_seq_nums_count; i++)
	{
		ChiakiTakionEvent event = { 0 };
		event.type = CHIAKI_TAKION_EVENT_TYPE_DATA_ACK;
		event.data_ack.seq_num = acked_seq_nums[i];
		takion->cb(&event, takion->cb_user);
	}
}

/**
 * Write a Takion message header of size MESSAGE_HEADER_SIZE to buf.
 *
 * This includes chunk_type, chunk_flags and payload_size
 *
 * @param raw_payload_size size of the actual data of the payload excluding type_a, type_b and payload_size
 */
static void takion_write_message_header(uint8_t *buf, uint32_t tag, uint64_t key_pos, uint8_t chunk_type, uint8_t chunk_flags, size_t payload_data_size)
{
	*((chiaki_unaligned_uint32_t *)(buf + 0)) = htonl(tag);
	memset(buf + 4, 0, CHIAKI_GKCRYPT_GMAC_SIZE);
	*((chiaki_unaligned_uint32_t *)(buf + 8)) = htonl(key_pos);
	*(buf + 0xc) = chunk_type;
	*(buf + 0xd) = chunk_flags;
	*((chiaki_unaligned_uint16_t *)(buf + 0xe)) = htons((uint16_t)(payload_data_size + 4));
}

static ChiakiErrorCode takion_parse_message(ChiakiTakion *takion, uint8_t *buf, size_t buf_size, TakionMessage *msg)
{
	if(buf_size < TAKION_MESSAGE_HEADER_SIZE)
	{
		CHIAKI_LOGE(takion->log, "Takion message received that is too short");
		return CHIAKI_ERR_INVALID_DATA;
	}

	msg->tag = ntohl(*((chiaki_unaligned_uint32_t *)buf));
	uint32_t key_pos_low = ntohl(*((chiaki_unaligned_uint32_t *)(buf + 0x8)));
	msg->key_pos = chiaki_key_state_request_pos(&takion->key_state, key_pos_low, true);
	msg->chunk_type = buf[0xc];
	msg->chunk_flags = buf[0xd];
	msg->payload_size = ntohs(*((chiaki_unaligned_uint16_t *)(buf + 0xe)));

	if(msg->tag != takion->tag_local)
	{
		CHIAKI_LOGE(takion->log, "Takion received message tag mismatch");
		return CHIAKI_ERR_INVALID_DATA;
	}

	if(buf_size != msg->payload_size + 0xc)
	{
		CHIAKI_LOGE(takion->log, "Takion received message payload size mismatch");
		return CHIAKI_ERR_INVALID_DATA;
	}

	msg->payload_size -= 0x4;

	if(msg->payload_size > 0)
		msg->payload = buf + 0x10;
	else
		msg->payload = NULL;

	return CHIAKI_ERR_SUCCESS;
}

static ChiakiErrorCode takion_send_message_init(ChiakiTakion *takion, TakionMessagePayloadInit *payload)
{
	uint8_t message[1 + TAKION_MESSAGE_HEADER_SIZE + 0x10];
	message[0] = TAKION_PACKET_TYPE_CONTROL;
	takion_write_message_header(message + 1, takion->tag_remote, 0, TAKION_CHUNK_TYPE_INIT, 0, 0x10);

	uint8_t *pl = message + 1 + TAKION_MESSAGE_HEADER_SIZE;
	*((chiaki_unaligned_uint32_t *)(pl + 0)) = htonl(payload->tag);
	*((chiaki_unaligned_uint32_t *)(pl + 4)) = htonl(payload->a_rwnd);
	*((chiaki_unaligned_uint16_t *)(pl + 8)) = htons(payload->outbound_streams);
	*((chiaki_unaligned_uint16_t *)(pl + 0xa)) = htons(payload->inbound_streams);
	*((chiaki_unaligned_uint32_t *)(pl + 0xc)) = htonl(payload->initial_seq_num);

	return chiaki_takion_send_raw(takion, message, sizeof(message));
}

static ChiakiErrorCode takion_send_message_cookie(ChiakiTakion *takion, uint8_t *cookie)
{
	uint8_t message[1 + TAKION_MESSAGE_HEADER_SIZE + TAKION_COOKIE_SIZE];
	message[0] = TAKION_PACKET_TYPE_CONTROL;
	takion_write_message_header(message + 1, takion->tag_remote, 0, TAKION_CHUNK_TYPE_COOKIE, 0, TAKION_COOKIE_SIZE);
	memcpy(message + 1 + TAKION_MESSAGE_HEADER_SIZE, cookie, TAKION_COOKIE_SIZE);
	return chiaki_takion_send_raw(takion, message, sizeof(message));
}

static ChiakiErrorCode takion_recv_message_init_ack(ChiakiTakion *takion, TakionMessagePayloadInitAck *payload)
{
	uint8_t message[1 + TAKION_MESSAGE_HEADER_SIZE + 0x10 + TAKION_COOKIE_SIZE];
	size_t received_size = sizeof(message);
	ChiakiErrorCode err = takion_recv(takion, message, &received_size, TAKION_EXPECT_TIMEOUT_MS);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;

	if(received_size < sizeof(message))
	{
		CHIAKI_LOGE(takion->log, "Takion received packet of size %zu while expecting init ack packet of exactly %zu", received_size, sizeof(message));
		return CHIAKI_ERR_INVALID_RESPONSE;
	}

	if(message[0] != TAKION_PACKET_TYPE_CONTROL)
	{
		CHIAKI_LOGE(takion->log, "Takion received packet of type %#x while expecting init ack message with type %#x", message[0], TAKION_PACKET_TYPE_CONTROL);
		return CHIAKI_ERR_INVALID_RESPONSE;
	}

	TakionMessage msg;
	err = takion_parse_message(takion, message + 1, received_size - 1, &msg);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(takion->log, "Failed to parse message while expecting init ack");
		return CHIAKI_ERR_INVALID_RESPONSE;
	}

	if(msg.chunk_type != TAKION_CHUNK_TYPE_INIT_ACK || msg.chunk_flags != 0x0)
	{
		CHIAKI_LOGE(takion->log, "Takion received unexpected message with type (%#x, %#x) while expecting init ack", msg.chunk_type, msg.chunk_flags);
		return CHIAKI_ERR_INVALID_RESPONSE;
	}

	assert(msg.payload_size == 0x10 + TAKION_COOKIE_SIZE);

	uint8_t *pl = msg.payload;
	payload->tag = ntohl(*((chiaki_unaligned_uint32_t *)(pl + 0)));
	payload->a_rwnd = ntohl(*((chiaki_unaligned_uint32_t *)(pl + 4)));
	payload->outbound_streams = ntohs(*((chiaki_unaligned_uint16_t *)(pl + 8)));
	payload->inbound_streams = ntohs(*((chiaki_unaligned_uint16_t *)(pl + 0xa)));
	payload->initial_seq_num = ntohl(*((chiaki_unaligned_uint32_t *)(pl + 0xc)));
	memcpy(payload->cookie, pl + 0x10, TAKION_COOKIE_SIZE);

	return CHIAKI_ERR_SUCCESS;
}

static ChiakiErrorCode takion_recv_message_cookie_ack(ChiakiTakion *takion)
{
	uint8_t message[1 + TAKION_MESSAGE_HEADER_SIZE];
	size_t received_size = sizeof(message);
	ChiakiErrorCode err = takion_recv(takion, message, &received_size, TAKION_EXPECT_TIMEOUT_MS);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;

	if(message[0xd] == TAKION_CHUNK_TYPE_INIT_ACK)
	{
		CHIAKI_LOGI(takion->log, "Received second init ack, looking for cookie ack in next message");
		err = takion_recv(takion, message, &received_size, TAKION_EXPECT_TIMEOUT_MS);
		if(err != CHIAKI_ERR_SUCCESS)
			return err;
	}

	if(received_size < sizeof(message))
	{
		CHIAKI_LOGE(takion->log, "Takion received packet of size %zu while expecting cookie ack packet of exactly %zu", received_size, sizeof(message));
		return CHIAKI_ERR_INVALID_RESPONSE;
	}

	if(message[0] != TAKION_PACKET_TYPE_CONTROL)
	{
		CHIAKI_LOGE(takion->log, "Takion received packet of type %#x while expecting cookie ack message with type %#x", message[0], TAKION_PACKET_TYPE_CONTROL);
		return CHIAKI_ERR_INVALID_RESPONSE;
	}

	TakionMessage msg;
	err = takion_parse_message(takion, message + 1, received_size - 1, &msg);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(takion->log, "Failed to parse message while expecting cookie ack");
		return CHIAKI_ERR_INVALID_RESPONSE;
	}

	if(msg.chunk_type != TAKION_CHUNK_TYPE_COOKIE_ACK || msg.chunk_flags != 0x0)
	{
		CHIAKI_LOGE(takion->log, "Takion received unexpected message with type (%#x, %#x) while expecting cookie ack", msg.chunk_type, msg.chunk_flags);
		return CHIAKI_ERR_INVALID_RESPONSE;
	}

	assert(msg.payload_size == 0);

	return CHIAKI_ERR_SUCCESS;
}

static void takion_handle_packet_av(ChiakiTakion *takion, uint8_t base_type, uint8_t *buf, size_t buf_size)
{
	// HHIxIIx
	// buf ownership is taken by this function (freed on error or transferred to queue entry).
	assert(base_type == TAKION_PACKET_TYPE_VIDEO || base_type == TAKION_PACKET_TYPE_AUDIO);
	if((takion->disable_audio_video & CHIAKI_VIDEO_DISABLED) && (base_type == TAKION_PACKET_TYPE_VIDEO))
	{
		free(buf);
		return;
	}
	ChiakiTakionAVPacket packet;
	ChiakiErrorCode err = takion->av_packet_parse(&packet, &takion->key_state, buf, buf_size);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		if(err == CHIAKI_ERR_BUF_TOO_SMALL)
			CHIAKI_LOGE(takion->log, "Takion received AV packet that was too small");
		free(buf);
		return;
	}
	if((takion->disable_audio_video & CHIAKI_AUDIO_DISABLED) && (base_type == TAKION_PACKET_TYPE_AUDIO) && !packet.is_haptics)
	{
		free(buf);
		return;
	}

	bool is_video = (base_type == TAKION_PACKET_TYPE_VIDEO);
	if(!is_video)
	{
		if(takion->cb)
		{
			ChiakiTakionEvent event = { 0 };
			event.type = CHIAKI_TAKION_EVENT_TYPE_AV;
			event.av = &packet;
			takion->cb(&event, takion->cb_user);
		}
		free(buf);
		return;
	}
	ChiakiReorderQueue *queue = &takion->video_queue;
	bool *initialized = &takion->video_queue_initialized;
	int64_t *head_wait = &takion->video_queue_head_wait_start_us;
	uint64_t *head_wait_seq_num = &takion->video_queue_head_wait_seq_num;
	size_t size_exp = TAKION_AV_VIDEO_REORDER_QUEUE_SIZE_EXP;

	if(!*initialized)
	{
		ChiakiSeqNum16 queue_begin = packet.packet_index;
		if(packet.unit_index > 0)
			queue_begin = (ChiakiSeqNum16)(packet.packet_index - packet.unit_index);
		if(chiaki_reorder_queue_init_16(queue, size_exp, queue_begin) != CHIAKI_ERR_SUCCESS)
		{
			// Fallback: dispatch immediately without reordering
			if(takion->cb)
			{
				ChiakiTakionEvent event = { 0 };
				event.type = CHIAKI_TAKION_EVENT_TYPE_AV;
				event.av = &packet;
				takion->cb(&event, takion->cb_user);
			}
			free(buf);
			return;
		}
		chiaki_reorder_queue_set_drop_strategy(queue, CHIAKI_REORDER_QUEUE_DROP_STRATEGY_BEGIN);
		chiaki_reorder_queue_set_drop_cb(queue, takion_av_drop, takion);
		*initialized = true;
		*head_wait = 0;
		*head_wait_seq_num = queue_begin;
	}

	TakionAVPacketEntry *entry = malloc(sizeof(TakionAVPacketEntry));
	if(!entry)
	{
		free(buf);
		return;
	}
	entry->base_type = base_type;
	entry->buf = buf;
	entry->buf_size = buf_size;
	entry->packet = packet;

	p5m_packets_note_video(takion, packet.frame_index, buf_size);
	chiaki_reorder_queue_push(queue, packet.packet_index, entry);
	takion_av_queue_flush_with_timeout(takion, queue, head_wait, head_wait_seq_num);
}

static ChiakiErrorCode av_packet_parse(bool v12, bool v20, ChiakiTakionAVPacket *packet, ChiakiKeyState *key_state, uint8_t *buf, size_t buf_size)
{
	memset(packet, 0, sizeof(ChiakiTakionAVPacket));

	size_t ext = v20 ? CHIAKI_TAKION_EXT_HEADER_SIZE : 0;
	if(buf_size < 1 + ext)
		return CHIAKI_ERR_BUF_TOO_SMALL;

	uint8_t base_type = buf[0] & TAKION_PACKET_BASE_TYPE_MASK;

	if(base_type != TAKION_PACKET_TYPE_VIDEO && base_type != TAKION_PACKET_TYPE_AUDIO)
		return CHIAKI_ERR_INVALID_DATA;

	packet->is_video = base_type == TAKION_PACKET_TYPE_VIDEO;
	packet->audio_kind = 0;
	packet->audio_single_unit = false;

	packet->uses_nalu_info_structs = ((buf[0] >> 4) & 1) != 0;

	uint8_t *av = buf + 1 + ext;
	size_t av_size = buf_size - 1 - ext;
	size_t av_header_size = v12
		? (packet->is_video ? CHIAKI_TAKION_V12_AV_HEADER_SIZE_VIDEO : CHIAKI_TAKION_V12_AV_HEADER_SIZE_AUDIO)
		: (packet->is_video ? CHIAKI_TAKION_V9_AV_HEADER_SIZE_VIDEO : CHIAKI_TAKION_V9_AV_HEADER_SIZE_AUDIO);
	if(av_size < av_header_size + 1)
		return CHIAKI_ERR_BUF_TOO_SMALL;

	packet->packet_index = ntohs(*((chiaki_unaligned_uint16_t *)(av + 0)));
	packet->frame_index = ntohs(*((chiaki_unaligned_uint16_t *)(av + 2)));

	uint32_t dword_2 = ntohl(*((chiaki_unaligned_uint32_t *)(av + 4)));
	if(packet->is_video)
	{
		packet->unit_index = (uint16_t)((dword_2 >> 0x15) & 0x7ff);
		packet->units_in_frame_total = (uint16_t)(((dword_2 >> 0xa) & 0x7ff) + 1);
		packet->units_in_frame_fec = (uint16_t)(dword_2 & 0x3ff);
	}
	else
	{
		packet->unit_index = (uint16_t)((dword_2 >> 0x18) & 0xff);
		packet->units_in_frame_total = (uint16_t)(((dword_2 >> 0x10) & 0xff) + 1);
		packet->units_in_frame_fec = (uint16_t)(dword_2 & 0xffff);
	}
	// v20 audio: bits 12-15 are a mode. In mode 2 the low 12 bits are the FEC unit count and every
	// unit has the same size (data size / total units); translated below to the v12 layout.
	uint8_t v20_audio_mode = (v20 && !packet->is_video) ? (uint8_t)((dword_2 >> 12) & 0xf) : 0;
	uint16_t v20_audio_fec = (uint16_t)(dword_2 & 0xfff);

	packet->codec = av[8];
	uint32_t key_pos_low = ntohl(*((chiaki_unaligned_uint32_t *)(av + 0xd)));
	packet->key_pos = chiaki_key_state_request_pos(key_state, key_pos_low, true);

	uint8_t unknown_1 = av[0x11]; (void)unknown_1;

	av += 0x11;
	av_size -= 0x11;

	if(packet->is_video)
	{
		packet->word_at_0x18 = ntohs(*((chiaki_unaligned_uint16_t *)(av + 0)));
		packet->adaptive_stream_index = av[2] >> 5;
		av += 3;
		av_size -= 3;
	}
	else
	{
		av += 1;
		av_size -= 1;
		// unknown
	}

	// TODO: parsing for uses_nalu_info_structs (before: packet.byte_at_0x1a)

	if(packet->is_video)
	{
		packet->byte_at_0x2c = av[0];
		//av += 2;
		//av_size -= 2;
	}

	if(packet->uses_nalu_info_structs)
	{
		av += 3;
		av_size -= 3;
	}

	if(v12 && !packet->is_video)
	{
		// v20 uses the high nibble of this byte for something new
		packet->audio_kind = *av;
		packet->is_haptics = (v20 ? (*av & 0xf) : *av) == 0x02;
		av += 1;
		av_size -= 1;
	}

	packet->data = av;
	packet->data_size = av_size;

	if(v20_audio_mode == 2)
	{
		size_t total = packet->units_in_frame_total;
		size_t unit_size = total ? av_size / total : 0;
		if(!total || v20_audio_fec >= total || total - v20_audio_fec > 0xf || v20_audio_fec > 0xf || unit_size > 0xff)
			return CHIAKI_ERR_INVALID_DATA;
		packet->units_in_frame_fec = (uint16_t)((unit_size << 8) | (v20_audio_fec << 4) | (total - v20_audio_fec));
	}
	else if(v20_audio_mode == 1)
	{
		// Multicanal: cada pacote leva uma unidade inteira (fonte ou FEC) do quadro.
		if(v20_audio_fec >= packet->units_in_frame_total || packet->unit_index >= packet->units_in_frame_total)
			return CHIAKI_ERR_INVALID_DATA;
		packet->audio_single_unit = true;
		packet->units_in_frame_fec = v20_audio_fec;
	}

	return CHIAKI_ERR_SUCCESS;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_takion_v9_av_packet_parse(ChiakiTakionAVPacket *packet, ChiakiKeyState *key_state, uint8_t *buf, size_t buf_size)
{
	return av_packet_parse(false, false, packet, key_state, buf, buf_size);
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_takion_v12_av_packet_parse(ChiakiTakionAVPacket *packet, ChiakiKeyState *key_state, uint8_t *buf, size_t buf_size)
{
	return av_packet_parse(true, false, packet, key_state, buf, buf_size);
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_takion_v20_av_packet_parse(ChiakiTakionAVPacket *packet, ChiakiKeyState *key_state, uint8_t *buf, size_t buf_size)
{
	return av_packet_parse(true, true, packet, key_state, buf, buf_size);
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_takion_v7_av_packet_format_header(uint8_t *buf, size_t buf_size, size_t *header_size_out, ChiakiTakionAVPacket *packet)
{
	size_t header_size = CHIAKI_TAKION_V7_AV_HEADER_SIZE_BASE;
	if(packet->is_video)
		header_size += CHIAKI_TAKION_V7_AV_HEADER_SIZE_VIDEO_ADD;
	if(packet->uses_nalu_info_structs)
		header_size += CHIAKI_TAKION_V7_AV_HEADER_SIZE_NALU_INFO_STRUCTS_ADD;
	*header_size_out = header_size;

	if(header_size > buf_size)
		return CHIAKI_ERR_BUF_TOO_SMALL;

	buf[0] = packet->is_video ? TAKION_PACKET_TYPE_VIDEO : TAKION_PACKET_TYPE_AUDIO;
	if(packet->uses_nalu_info_structs)
		buf[0] |= 0x10;

	*(chiaki_unaligned_uint16_t *)(buf + 1) = htons(packet->packet_index);
	*(chiaki_unaligned_uint16_t *)(buf + 3) = htons(packet->frame_index);

	*(chiaki_unaligned_uint32_t *)(buf + 5) = htonl(
			(packet->units_in_frame_fec & 0x3ff)
			| (((packet->units_in_frame_total - 1) & 0x7ff) << 0xa)
			| ((packet->unit_index & 0xffff) << 0x15));

	buf[9] = packet->codec & 0xff;

	*(chiaki_unaligned_uint32_t *)(buf + 0xa) = 0; // unknown

	*(chiaki_unaligned_uint32_t *)(buf + 0xe) = (uint32_t)packet->key_pos;

	uint8_t *cur = buf + 0x12;
	if(packet->is_video)
	{
		*(chiaki_unaligned_uint16_t *)cur = htons(packet->word_at_0x18);
		cur[2] = packet->adaptive_stream_index << 5;
		cur += 3;
	}

	if(packet->uses_nalu_info_structs)
	{
		*(chiaki_unaligned_uint16_t *)cur = 0; // unknown
		cur[2] = 0; // unknown
	}

	return CHIAKI_ERR_SUCCESS;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_takion_v7_av_packet_parse(ChiakiTakionAVPacket *packet, ChiakiKeyState *key_state, uint8_t *buf, size_t buf_size)
{
	memset(packet, 0, sizeof(ChiakiTakionAVPacket));

	if(buf_size < 1)
		return CHIAKI_ERR_BUF_TOO_SMALL;

	uint8_t base_type = buf[0] & TAKION_PACKET_BASE_TYPE_MASK;

	if(base_type != TAKION_PACKET_TYPE_VIDEO && base_type != TAKION_PACKET_TYPE_AUDIO)
		return CHIAKI_ERR_INVALID_DATA;

	packet->is_video = base_type == TAKION_PACKET_TYPE_VIDEO;
	packet->uses_nalu_info_structs = ((buf[0] >> 4) & 1) != 0;

	size_t header_size = CHIAKI_TAKION_V7_AV_HEADER_SIZE_BASE;
	if(packet->is_video)
		header_size += CHIAKI_TAKION_V7_AV_HEADER_SIZE_VIDEO_ADD;
	if(packet->uses_nalu_info_structs)
		header_size += CHIAKI_TAKION_V7_AV_HEADER_SIZE_NALU_INFO_STRUCTS_ADD;

	if(buf_size < header_size)
		return CHIAKI_ERR_BUF_TOO_SMALL;

	packet->packet_index = ntohs(*((chiaki_unaligned_uint16_t *)(buf + 1)));
	packet->frame_index = ntohs(*((chiaki_unaligned_uint16_t *)(buf + 3)));

	uint32_t dword_2 = ntohl(*((chiaki_unaligned_uint32_t *)(buf + 5)));
	packet->unit_index = (uint16_t)((dword_2 >> 0x15) & 0x7ff);
	packet->units_in_frame_total = (uint16_t)(((dword_2 >> 0xa) & 0x7ff) + 1);
	packet->units_in_frame_fec = (uint16_t)(dword_2 & 0x3ff);

	packet->codec = buf[9];
	// unknown *(chiaki_unaligned_uint32_t *)(buf + 0xa)
	packet->key_pos = ntohl(*((chiaki_unaligned_uint32_t *)(buf + 0xe)));

	buf += 0x12;
	buf_size -= 0x12;

	if(packet->is_video)
	{
		packet->word_at_0x18 = ntohs(*((chiaki_unaligned_uint16_t *)(buf + 0)));
		packet->adaptive_stream_index = buf[2] >> 5;
		buf += 3;
		buf_size -= 3;
	}

	if(packet->uses_nalu_info_structs)
	{
		buf += 3;
		buf_size -= 3;
		// unknown
	}

	packet->data = buf;
	packet->data_size = buf_size;

	return CHIAKI_ERR_SUCCESS;
}

static ChiakiErrorCode takion_read_extra_sock_messages(ChiakiTakion *takion)
{
	// Stop trying after 1s
	uint64_t expired = 1000 + chiaki_time_now_monotonic_ms();
    while (true)
    {
		uint64_t now = chiaki_time_now_monotonic_ms();
		if(now > expired)
			return CHIAKI_ERR_TIMEOUT;
		uint8_t buf[1500];
		ChiakiErrorCode err = chiaki_stop_pipe_select_single(&takion->stop_pipe, takion->sock, false, 200);
		if(err != CHIAKI_ERR_SUCCESS)
			return err;
        CHIAKI_SSIZET_TYPE len = recv(takion->sock, (CHIAKI_SOCKET_BUF_TYPE) buf, sizeof(buf), 0);
        if (len < 0)
            return CHIAKI_ERR_NETWORK;
	}
}
