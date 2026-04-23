<script setup>
defineProps({
  headers: { type: Array, required: true },
  rows: { type: Array, required: true },
})
</script>

<template>
  <table class="w-full text-sm">
    <thead>
      <tr>
        <th
          v-for="h in headers"
          :key="h"
          class="text-left py-2 px-3 border-b border-[var(--rh-border)] font-['Red_Hat_Display'] text-[var(--rh-red)] uppercase text-xs tracking-wider"
        >
          {{ h }}
        </th>
      </tr>
    </thead>
    <tbody>
      <tr
        v-for="(row, i) in rows"
        :key="i"
        class="border-b border-[var(--rh-border)] hover:bg-[var(--rh-surface)]"
      >
        <td v-for="(cell, j) in row" :key="j" class="py-2 px-3">{{ cell }}</td>
      </tr>
    </tbody>
  </table>
</template>
