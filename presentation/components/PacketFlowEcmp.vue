<template>
  <div class="packet-flow-ecmp">
    <div class="packet-flow-ecmp__sizer">
      <svg
        viewBox="0 0 600 320"
        class="packet-flow-ecmp__svg"
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
      <text x="110" y="196" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="7" fill="#F0F0F0">worker-0</text>
      <text x="110" y="208" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="5" fill="#A8A8A8">(ECMP hit - no BGP)</text>

      <rect x="220" y="180" width="120" height="36" rx="4" fill="#242424" stroke="#383838" stroke-width="1.5"/>
      <text x="280" y="196" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="7" fill="#F0F0F0">worker-1</text>
      <text x="280" y="208" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="5" fill="#5BA352">(BGP active)</text>

      <rect x="390" y="180" width="120" height="36" rx="4" fill="#242424" stroke="#EE0000" stroke-width="1.5"/>
      <text x="450" y="196" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="7" fill="#F0F0F0">worker-2</text>
      <text x="450" y="208" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="5" fill="#EE0000">(return - no conntrack)</text>

      <!-- CUDN VM box -->
      <rect x="210" y="268" width="180" height="36" rx="4" fill="#242424" stroke="#383838" stroke-width="1.5"/>
      <text x="300" y="289" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="8" fill="#F0F0F0">CUDN VM (10.128.0.x)</text>

      <!-- Topology lines -->
      <!-- VM to workers (OVN overlay) -->
      <line x1="300" y1="268" x2="110" y2="216" stroke="#383838" stroke-width="1" stroke-dasharray="4,3"/>
      <line x1="300" y1="268" x2="280" y2="216" stroke="#383838" stroke-width="1" stroke-dasharray="4,3"/>
      <line x1="300" y1="268" x2="450" y2="216" stroke="#383838" stroke-width="1" stroke-dasharray="4,3"/>

      <!-- Workers to Cloud Router -->
      <line x1="110" y1="180" x2="250" y2="116" stroke="#383838" stroke-width="1"/>
      <line x1="280" y1="180" x2="280" y2="116" stroke="#383838" stroke-width="1"/>
      <line x1="450" y1="180" x2="350" y2="116" stroke="#383838" stroke-width="1"/>

      <!-- Cloud Router to Internet -->
      <line x1="300" y1="80" x2="300" y2="46" stroke="#383838" stroke-width="1"/>

      <!-- Outbound packet path: VM → worker-0 → Cloud Router → Internet -->
      <circle class="pkt-out" cx="300" cy="268" r="5" fill="#73BCF7"/>

      <!-- Return packet path: Internet → Cloud Router → worker-2 → DROP -->
      <circle class="pkt-ret" cx="300" cy="46" r="5" fill="#EE0000"/>

      <!-- Drop X mark at worker-2 -->
      <text class="drop-label" x="450" y="250" text-anchor="middle" font-family="Red Hat Display, sans-serif" font-size="11" fill="#EE0000" opacity="0">✗</text>

      <!-- Label -->
      <text x="300" y="312" text-anchor="middle" font-family="Red Hat Display, sans-serif" font-size="6.5" fill="#EE0000">ct_state=!est → DROP (~78% of connections)</text>
      </svg>
    </div>
  </div>
</template>

<style scoped>
/* Slidev’s slide flex chain can give svg height:auto a collapsed used height; aspect-ratio
   wrapper reserves vertical space matching the 600×320 viewBox. */
/* Shared cycle: request ~0–48%, return ~52–100% (same duration on both circles keeps phases aligned). */
.packet-flow-ecmp {
  width: 100%;
  display: flex;
  justify-content: center;
  flex-shrink: 0;
  --pkt-cycle: 5s;
  --pkt-delay: 0.5s;
}

.packet-flow-ecmp__sizer {
  width: min(100%, 720px);
  aspect-ratio: 600 / 320;
  position: relative;
}

.packet-flow-ecmp__svg {
  position: absolute;
  inset: 0;
  display: block;
  width: 100%;
  height: 100%;
}

/* Outbound: VM(300,268) → worker-0(110,198) → CloudRouter(250,98) → Internet(300,28) */
@keyframes pkt-out-move {
  0%   { cx: 300; cy: 268; opacity: 1; }
  14%  { cx: 110; cy: 198; opacity: 1; }
  30%  { cx: 250; cy: 98;  opacity: 1; }
  44%  { cx: 300; cy: 28;  opacity: 1; }
  48%  { cx: 300; cy: 28;  opacity: 0; }
  49%,
  100% { cx: 300; cy: 28;  opacity: 0; }
}

/* Return: Internet(300,28) → CloudRouter(350,98) → worker-2(450,198) → flash red → disappear */
@keyframes pkt-ret-move {
  0%,
  50%  { cx: 300; cy: 28;  opacity: 0; }
  52%  { cx: 300; cy: 28;  opacity: 1; }
  64%  { cx: 350; cy: 98;  opacity: 1; }
  86%  { cx: 450; cy: 198; opacity: 1; fill: #EE0000; }
  93%  { cx: 450; cy: 220; opacity: 1; fill: #EE0000; }
  100% { cx: 450; cy: 220; opacity: 0; }
}

@keyframes drop-appear {
  0%,
  88%  { opacity: 0; }
  90%,
  96%  { opacity: 1; }
  100% { opacity: 0; }
}

.pkt-out {
  animation: pkt-out-move var(--pkt-cycle) ease-in-out var(--pkt-delay) infinite;
}

.pkt-ret {
  animation: pkt-ret-move var(--pkt-cycle) ease-in-out var(--pkt-delay) infinite;
}

.drop-label {
  animation: drop-appear var(--pkt-cycle) ease-in-out var(--pkt-delay) infinite;
}
</style>
