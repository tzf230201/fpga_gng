<template>
  <div v-if="$slidev.nav.currentPage !== 1" class="deck-page">
    {{ $slidev.nav.currentPage }} / {{ $slidev.nav.total }}
  </div>
</template>
