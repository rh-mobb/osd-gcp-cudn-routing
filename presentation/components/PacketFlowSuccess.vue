<template>
  <div class="packet-flow-success">
    <div class="packet-flow-success__sizer">
      <svg
        viewBox="0 0 600 320"
        class="packet-flow-success__svg"
        preserveAspectRatio="xMidYMid meet"
        xmlns="http://www.w3.org/2000/svg"
      >
      <!-- Internet box -->
      <rect x="250" y="10" width="100" height="36" rx="4" fill="#242424" stroke="#383838" stroke-width="1.5"/>
      <text x="300" y="32" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="8" fill="#F0F0F0">Internet</text>

      <!-- Cloud Router box -->
      <rect x="200" y="80" width="200" height="36" rx="4" fill="#242424" stroke="#73BCF7" stroke-width="1.5"/>
      <text x="300" y="101" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="8" fill="#73BCF7">Cloud Router (NCC)</text>

      <!-- Worker boxes -->
      <rect x="50" y="180" width="120" height="36" rx="4" fill="#242424" stroke="#383838" stroke-width="1.5"/>
      <text x="110" y="198" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="7" fill="#A8A8A8">worker-0</text>

      <rect x="220" y="180" width="120" height="36" rx="4" fill="#242424" stroke="#5BA352" stroke-width="2"/>
      <text x="280" y="196" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="7" fill="#F0F0F0">worker-1</text>
      <text x="280" y="208" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="5" fill="#5BA352">(BGP active)</text>

      <rect x="390" y="180" width="120" height="36" rx="4" fill="#242424" stroke="#383838" stroke-width="1.5"/>
      <text x="450" y="198" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="7" fill="#A8A8A8">worker-2</text>

      <!-- CUDN VM box -->
      <rect x="210" y="268" width="180" height="36" rx="4" fill="#242424" stroke="#383838" stroke-width="1.5"/>
      <text x="300" y="289" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="8" fill="#F0F0F0">CUDN VM (10.128.0.x)</text>

      <!-- Topology lines -->
      <line x1="300" y1="268" x2="110" y2="216" stroke="#383838" stroke-width="1" stroke-dasharray="4,3"/>
      <line x1="300" y1="268" x2="280" y2="216" stroke="#5BA352" stroke-width="1.5" stroke-dasharray="4,3"/>
      <line x1="300" y1="268" x2="450" y2="216" stroke="#383838" stroke-width="1" stroke-dasharray="4,3"/>

      <line x1="110" y1="180" x2="250" y2="116" stroke="#383838" stroke-width="1"/>
      <line x1="280" y1="180" x2="280" y2="116" stroke="#5BA352" stroke-width="1.5"/>
      <line x1="450" y1="180" x2="350" y2="116" stroke="#383838" stroke-width="1"/>

      <line x1="300" y1="80" x2="300" y2="46" stroke="#383838" stroke-width="1"/>

      <!-- Firewall allow rule badge -->
      <rect x="370" y="80" width="115" height="22" rx="3" fill="#1a2e1a" stroke="#5BA352" stroke-width="1"/>
      <text x="427" y="94" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="5" fill="#5BA352">allow 0.0.0.0/0 ✓</text>

      <!-- Outbound packet: VM → worker-1 → CloudRouter → Internet -->
      <circle class="pkt-out" cx="300" cy="268" r="5" fill="#5BA352"/>

      <!-- Return packet: Internet → CloudRouter → worker-1 → VM -->
      <circle class="pkt-ret" cx="300" cy="46" r="5" fill="#5BA352"/>

      <!-- Success checkmark -->
      <text class="success-label" x="300" y="258" text-anchor="middle" font-family="Red Hat Display, sans-serif" font-size="11" fill="#5BA352" opacity="0">✓</text>

      <!-- Label -->
      <text x="300" y="312" text-anchor="middle" font-family="Red Hat Display, sans-serif" font-size="6.5" fill="#5BA352">allow 0.0.0.0/0 → 100% success</text>
      </svg>
    </div>
  </div>
</template>

<style scoped>
/* Shared cycle: request first half, return second half (same duration keeps phases aligned). */
.packet-flow-success {
  width: 100%;
  display: flex;
  justify-content: center;
  flex-shrink: 0;
  --pkt-cycle: 5s;
  --pkt-delay: 0.5s;
}

.packet-flow-success__sizer {
  width: min(100%, 720px);
  aspect-ratio: 600 / 320;
  position: relative;
}

.packet-flow-success__svg {
  position: absolute;
  inset: 0;
  display: block;
  width: 100%;
  height: 100%;
}

/* Outbound: VM(300,268) → worker-1(280,198) → CloudRouter(280,98) → Internet(300,28) */
@keyframes pkt-out-move {
  0%   { cx: 300; cy: 268; opacity: 1; }
  18%  { cx: 280; cy: 198; opacity: 1; }
  34%  { cx: 280; cy: 98;  opacity: 1; }
  44%  { cx: 300; cy: 28;  opacity: 1; }
  48%  { cx: 300; cy: 28;  opacity: 0; }
  49%,
  100% { cx: 300; cy: 28;  opacity: 0; }
}

/* Return: Internet → CloudRouter → worker-1 → VM */
@keyframes pkt-ret-move {
  0%,
  50%  { cx: 300; cy: 28;  opacity: 0; }
  52%  { cx: 300; cy: 28;  opacity: 1; }
  66%  { cx: 280; cy: 98;  opacity: 1; }
  82%  { cx: 280; cy: 198; opacity: 1; }
  96%  { cx: 300; cy: 268; opacity: 1; fill: #5BA352; }
  100% { cx: 300; cy: 268; opacity: 0; }
}

@keyframes success-appear {
  0%,
  94%  { opacity: 0; }
  96%,
  99%  { opacity: 1; }
  100% { opacity: 0; }
}

.pkt-out {
  animation: pkt-out-move var(--pkt-cycle) ease-in-out var(--pkt-delay) infinite;
}

.pkt-ret {
  animation: pkt-ret-move var(--pkt-cycle) ease-in-out var(--pkt-delay) infinite;
}

.success-label {
  animation: success-appear var(--pkt-cycle) ease-in-out var(--pkt-delay) infinite;
}
</style>
