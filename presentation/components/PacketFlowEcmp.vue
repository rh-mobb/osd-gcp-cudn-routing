<template>
  <div class="packet-flow-ecmp">
    <svg viewBox="0 0 600 320" class="w-full h-full" xmlns="http://www.w3.org/2000/svg">
      <!-- Internet box -->
      <rect x="250" y="10" width="100" height="36" rx="4" fill="#242424" stroke="#383838" stroke-width="1.5"/>
      <text x="300" y="33" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="12" fill="#F0F0F0">Internet</text>

      <!-- Cloud Router box -->
      <rect x="200" y="80" width="200" height="36" rx="4" fill="#242424" stroke="#73BCF7" stroke-width="1.5"/>
      <text x="300" y="103" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="12" fill="#73BCF7">Cloud Router (NCC)</text>

      <!-- Worker boxes -->
      <rect x="50" y="180" width="120" height="36" rx="4" fill="#242424" stroke="#383838" stroke-width="1.5"/>
      <text x="110" y="198" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="11" fill="#F0F0F0">worker-0</text>
      <text x="110" y="212" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="9" fill="#A8A8A8">(ECMP hit - no BGP)</text>

      <rect x="220" y="180" width="120" height="36" rx="4" fill="#242424" stroke="#383838" stroke-width="1.5"/>
      <text x="280" y="198" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="11" fill="#F0F0F0">worker-1</text>
      <text x="280" y="212" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="9" fill="#5BA352">(BGP active)</text>

      <rect x="390" y="180" width="120" height="36" rx="4" fill="#242424" stroke="#EE0000" stroke-width="1.5"/>
      <text x="450" y="198" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="11" fill="#F0F0F0">worker-2</text>
      <text x="450" y="212" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="9" fill="#EE0000">(return - no conntrack)</text>

      <!-- CUDN VM box -->
      <rect x="210" y="268" width="180" height="36" rx="4" fill="#242424" stroke="#383838" stroke-width="1.5"/>
      <text x="300" y="291" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="12" fill="#F0F0F0">CUDN VM (10.128.0.x)</text>

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
      <text class="drop-label" x="450" y="250" text-anchor="middle" font-family="Red Hat Display, sans-serif" font-size="20" fill="#EE0000" opacity="0">✗</text>

      <!-- Label -->
      <text x="300" y="312" text-anchor="middle" font-family="Red Hat Display, sans-serif" font-size="11" fill="#EE0000">ct_state=!est → DROP (~78% of connections)</text>
    </svg>
  </div>
</template>

<style scoped>
.packet-flow-ecmp {
  width: 100%;
  height: 280px;
}

/* Outbound: VM(300,268) → worker-0(110,198) → CloudRouter(250,98) → Internet(300,28) */
@keyframes pkt-out-move {
  0%   { cx: 300; cy: 268; opacity: 1; }
  25%  { cx: 110; cy: 198; opacity: 1; }
  50%  { cx: 250; cy: 98;  opacity: 1; }
  75%  { cx: 300; cy: 28;  opacity: 1; }
  100% { cx: 300; cy: 28;  opacity: 0; }
}

/* Return: Internet(300,28) → CloudRouter(350,98) → worker-2(450,198) → flash red → disappear */
@keyframes pkt-ret-move {
  0%   { cx: 300; cy: 28;  opacity: 0; }
  20%  { cx: 300; cy: 28;  opacity: 1; }
  40%  { cx: 350; cy: 98;  opacity: 1; }
  70%  { cx: 450; cy: 198; opacity: 1; fill: #EE0000; }
  85%  { cx: 450; cy: 220; opacity: 1; fill: #EE0000; }
  100% { cx: 450; cy: 220; opacity: 0; }
}

@keyframes drop-appear {
  0%   { opacity: 0; }
  70%  { opacity: 0; }
  80%  { opacity: 1; }
  100% { opacity: 1; }
}

.pkt-out {
  animation: pkt-out-move 3s ease-in-out 0.5s infinite;
}

.pkt-ret {
  animation: pkt-ret-move 3s ease-in-out 0.5s infinite;
}

.drop-label {
  animation: drop-appear 3s ease-in-out 0.5s infinite;
}
</style>
