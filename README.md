# netns-fabric

> Linux 네트워크 네임스페이스, veth, Linux Bridge만으로 데이터센터 네트워크 토폴로지를 단계적으로 구축하는 프로젝트.

단일 L2 브로드캐스트 도메인에서 시작해 ECMP 라우팅이 적용된 풀 CLOS 스파인-리프 패브릭까지 4단계로 쌓아 올립니다.

## 구성

순차적으로 발전하는 4개의 스크립트:

| # | 스크립트                  | 만드는 것                                                     |
|---|---------------------------|---------------------------------------------------------------|
| 1 | `01-two-hosts.sh`         | veth 페어 하나로 연결된 네임스페이스 2개                      |
| 2 | `02-one-leaf.sh`          | Linux Bridge("리프") 1개에 같은 서브넷 호스트 4개             |
| 3 | `03-two-leaves-router.sh` | 라우터 네임스페이스를 통해 연결된 서로 다른 서브넷의 리프 2개 |
| 4 | `04-spine-leaf.sh`        | **2 스파인 × 4 리프 풀 CLOS 패브릭 (ECMP 라우팅)**            |


```
       ┌────────┐         ┌────────┐
       │ spine1 │         │ spine2 │
       └┬─┬─┬─┬─┘         └┬─┬─┬─┬─┘
        │ │ │ │  풀 메시   │ │ │ │
       ┌┴─┴─┴─┴-┐        ┌─┴─┴─┴─┴─┐
       │ 4 leaves        (L3라우터)│
       └────┬───┘        └────┬───-┘
            │                 │
      4개 호스트 (각자 다른 /24 서브넷)
```

모든 리프가 자체 L3 라우터입니다. 리프 간 트래픽은 두 스파인 중 어느 쪽이든 갈 수 있고, 흐름별 ECMP 해싱으로 분산됩니다.

## 요구사항

- Linux (또는 WSL2 — `5.15.x-microsoft-standard-WSL2`에서 검증)
- `iproute2`, `iputils-ping`, `traceroute`
- `sudo` 권한 (네임스페이스 조작에 root 필요)


설치:
```bash
sudo apt update
sudo apt install -y iproute2 iputils-ping traceroute
```

## 사용법

```bash
# 스파인-리프 패브릭 구축
make up

# 모든 호스트 쌍 연결성 검증 (12개 cross-leaf ping)
make verify

# ECMP가 두 스파인으로 트래픽 분산하는지 시연
make ecmp

# 전체 정리
make down
```

또는 각 단계를 직접 실행:
```bash
./04-spine-leaf.sh up
./04-spine-leaf.sh verify
./04-spine-leaf.sh ecmp
```

## 실행 결과

`make verify` — 연결성 매트릭스:
```
[?] Connectivity matrix (12 cross-leaf pings):
  [v] h1 -> h2
  [v] h1 -> h3
  ...
[v] All 12 pings passed!

[?] Sample routing table (leaf1) - notice ECMP nexthops:
    10.0.2.0/24
        nexthop via 10.99.11.1 dev l1-s1 weight 1
        nexthop via 10.99.21.1 dev l1-s2 weight 1
    ...
```

`make ecmp` — 트래픽이 두 스파인으로 분산:
```
Traffic distribution from leaf1 to spines:
  via spine1:   74 packets  (49%)
  via spine2:   76 packets  (51%)
```

## IP 설계

| 종류                   | 형식                  | 예시                             |
|------------------------|-----------------------|----------------------------------|
| 호스트 서브넷 (리프별) | `10.0.<L>.0/24`       | leaf3 호스트 → `10.0.3.0/24`     |
| 호스트 IP              | `10.0.<L>.10`         | h3 → `10.0.3.10`                 |
| 기본 게이트웨이        | `10.0.<L>.1`          | h3의 gw → `10.0.3.1`             |
| 트랜짓 서브넷          | `10.99.<S*10+L>.0/30` | spine2 ↔ leaf3 → `10.99.23.0/30` |
| 트랜짓의 스파인 쪽     | `.1`                  | spine2의 l3 포트 → `10.99.23.1`  |
| 트랜짓의 리프 쪽       | `.2`                  | leaf3의 s2 포트 → `10.99.23.2`   |

## 만들면서 배운 것

- **브리지 넷필터 함정**: Docker가 설치되면 `net.bridge.bridge-nf-call-iptables=1`로 바꿔놓아서, 같은 서브넷 안 브리지 트래픽도 iptables를 거치게 됩니다. 별다른 에러 메시지 없이 ping이 실패하는 상황이 발생. 스크립트에서 이 값을 명시적으로 0으로 설정해 해결.

## 검증된 환경

WSL2, 커널 `5.15.x-microsoft-standard-WSL2`에서 테스트 완료.
최종 검증: 2026-05.

## 확장 아이디어

이 프로젝트를 발전시킬 수 있는 방향:

- **정적 라우트를 BGP로 교체** — 각 라우터 네임스페이스에 FRR을 설치하고, RFC 7938 패턴의 BGP unnumbered 구성
- **VXLAN 오버레이 추가** — 리프 사이에 테넌트 트래픽 캡슐화
- **장애 주입** — 스파인 링크를 강제로 끊고 ECMP가 자동으로 우회하는지 관찰
- **Containerlab으로 마이그레이션** — 같은 토폴로지를 실제 NOS(SONiC, FRR, Arista cEOS)로 재구축

## 라이선스

MIT
