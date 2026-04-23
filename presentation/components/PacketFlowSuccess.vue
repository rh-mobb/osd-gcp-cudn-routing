<template>
  <div class="packet-flow-success">
    <svg viewBox="0 0 600 320" class="w-full h-full" xmlns="http://www.w3.org/2000/svg">
      <!-- Internet box -->
      <rect x="250" y="10" width="100" height="36" rx="4" fill="#242424" stroke="#383838" stroke-width="1.5"/>
      <text x="300" y="33" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="12" fill="#F0F0F0">Internet</text>

      <!-- Cloud Router box -->
      <rect x="200" y="80" width="200" height="36" rx="4" fill="#242424" stroke="#73BCF7" stroke-width="1.5"/>
      <text x="300" y="103" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="12" fill="#73BCF7">Cloud Router (NCC)</text>

      <!-- Worker boxes -->
      <rect x="50" y="180" width="120" height="36" rx="4" fill="#242424" stroke="#383838" stroke-width="1.5"/>
      <text x="110" y="198" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="11" fill="#A8A8A8">worker-0</text>

      <rect x="220" y="180" width="120" height="36" rx="4" fill="#242424" stroke="#5BA352" stroke-width="2"/>
      <text x="280" y="198" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="11" fill="#F0F0F0">worker-1</text>
      <text x="280" y="212" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="9" fill="#5BA352">(BGP active)</text>

      <rect x="390" y="180" width="120" height="36" rx="4" fill="#242424" stroke="#383838" stroke-width="1.5"/>
      <text x="450" y="198" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="11" fill="#A8A8A8">worker-2</text>

      <!-- CUDN VM box -->
      <rect x="210" y="268" width="180" height="36" rx="4" fill="#242424" stroke="#383838" stroke-width="1.5"/>
      <text x="300" y="291" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="12" fill="#F0F0F0">CUDN VM (10.128.0.x)</text>

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
      <text x="427" y="95" text-anchor="middle" font-family="Red Hat Text, sans-serif" font-size="9" fill="#5BA352">allow 0.0.0.0/0 ✓</text>

      <!-- Outbound packet: VM → worker-1 → CloudRouter → Internet -->
      <circle class="pkt-out" cx="300" cy="268" r="5" fill="#5BA352"/>

      <!-- Return packet: Internet → CloudRouter → worker-1 → VM -->
      <circle class="pkt-ret" cx="300" cy="46" r="5" fill="#5BA352"/>

      <!-- Success checkmark -->
      <text class="success-label" x="300" y="258" text-anchor="middle" font-family="Red Hat Display, sans-serif" font-size="20" fill="#5BA352" opacity="0">✓</text>

      <!-- Label -->
      <text x="300" y="312" text-anchor="middle" font-family="Red Hat Display, sans-serif" font-size="11" fill="#5BA352">allow 0.0.0.0/0 → 100% success</text>
    </svg>
  </div>
</template>

<style scoped>
.packet-flow-success {
  width: 100%;
  height: 280px;
}

/* Outbound: VM(300,268) → worker-1(280,198) → CloudRouter(280,98) → Internet(300,28) */
@keyframes pkt-out-move {
  0%   { cx: 300; cy: 268; opacity: 1; }
  30%  { cx: 280; cy: 198; opacity: 1; }
  60%  { cx: 280; cy: 98;  opacity: 1; }
  85%  { cx: 300; cy: 28;  opacity: 1; }
  100% { cx: 300; cy: 28;  opacity: 0; }
}

/* Return: Internet → CloudRouter → worker-1 → VM */
@keyframes pkt-ret-move {
  0%   { cx: 300; cy: 28;  opacity: 0; }
  15%  { cx: 300; cy: 28;  opacity: 1; }
  40%  { cx: 280; cy: 98;  opacity: 1; }
  65%  { cx: 280; cy: 198; opacity: 1; }
  90%  { cx: 300; cy: 268; opacity: 1; fill: #5BA352; }
  100% { cx: 300; cy: 268; opacity: 0; }
}

@keyframes success-appear {
  0%   { opacity: 0; }
  85%  { opacity: 0; }
  92%  { opacity: 1; }
  100% { opacity: 0; }
}

.pkt-out {
  animation: pkt-out-move 3s ease-in-out 0.5s infinite;
}

.pkt-ret {
  animation: pkt-ret-move 3s ease-in-out 0.5s infinite;
}

.success-label {
  animation: success-appear 3s ease-in-out 0.5s infinite;
}
</style>
