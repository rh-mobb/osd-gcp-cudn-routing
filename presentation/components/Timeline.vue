<script setup>
const milestones = [
  { date: 'Mar 4',  label: 'TF Provider\nstarts',       repo: 'tf-provider' },
  { date: 'Mar 18', label: 'Slack message\nfrom Shreyans', repo: 'tf-provider' },
  { date: 'Mar 26', label: 'First commit\nosd-gcp-cudn', repo: 'cudn' },
  { date: 'Mar 30', label: 'BGP pivot\n(no ILB)',        repo: 'cudn' },
  { date: 'Apr 2',  label: 'Go controller\nstarts',      repo: 'cudn' },
  { date: 'Apr 13', label: 'Operator /\nCRD design',     repo: 'cudn' },
  { date: 'Apr 17', label: 'Egress\ninvestigation',      repo: 'cudn' },
  { date: 'Apr 23', label: 'Smoking gun\nfound',         repo: 'cudn' },
]
const colors = { 'tf-provider': '#73BCF7', 'cudn': '#EE0000' }
</script>

<template>
  <div class="relative mt-4">
    <div class="h-px bg-[var(--rh-border)] w-full absolute" style="top: 24px" />
    <div class="flex justify-between relative">
      <div
        v-for="m in milestones"
        :key="m.date"
        class="flex flex-col items-center"
        style="flex: 1"
      >
        <div
          class="w-3 h-3 rounded-full z-10 mt-[18px]"
          :style="{ background: colors[m.repo] }"
        />
        <div
          class="text-[10px] text-center mt-2 leading-tight whitespace-pre-line"
          :style="{ color: 'var(--rh-muted)' }"
        >
          {{ m.label }}
        </div>
        <div class="text-[9px] mt-1" :style="{ color: 'var(--rh-border)' }">
          {{ m.date }}
        </div>
      </div>
    </div>
    <div class="flex gap-4 mt-4 text-[10px]" :style="{ color: 'var(--rh-muted)' }">
      <span>
        <span
          class="inline-block w-2 h-2 rounded-full mr-1"
          style="background: #73BCF7; vertical-align: middle"
        />tf-provider-osd-google
      </span>
      <span>
        <span
          class="inline-block w-2 h-2 rounded-full mr-1"
          style="background: #EE0000; vertical-align: middle"
        />osd-gcp-cudn-routing
      </span>
    </div>
  </div>
</template>
