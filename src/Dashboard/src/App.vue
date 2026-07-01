<script setup>
import { ResultSet } from '@drasi/signalr-vue';
import { ref, computed, onMounted } from 'vue';
const hubUrl = '/hub';
const participants = ref(8);
const status = ref('idle');
const collectiveTarget = computed(() => participants.value * 300_000);

async function fetchStatus() {
  status.value = (await (await fetch('/api/contest/status')).json()).status;
}
async function startContest() {
  await fetch(`/api/contest/start?participants=${participants.value}`, { method: 'POST' });
  await fetchStatus();
}
async function deleteContest() {
  await fetch('/api/contest/delete', { method: 'POST' });
  await fetchStatus();
}
onMounted(() => { fetchStatus(); setInterval(fetchStatus, 5000); });
</script>

<template>
  <main>
    <h1>🏆 StepUp Leaderboard</h1>

    <form class="start" @submit.prevent="startContest">
      <input type="number" v-model.number="participants" min="2" max="20" />
      <button type="submit">Start contest</button>
      <button type="button" @click="deleteContest">Delete contest</button>
      <span class="status" :class="`status--${status}`">{{ status }}</span>
    </form>

    <!-- Group progress -->
    <ResultSet :url="hubUrl" queryId="collective-progress">
      <template #default="{ item }">
        <section class="progress">
          <div class="progress__label">
            <span>Group progress</span>
            <span>{{ (item.total ?? 0).toLocaleString() }} / {{ collectiveTarget.toLocaleString() }} steps</span>
          </div>
          <progress :value="item.total ?? 0" :max="collectiveTarget"></progress>
        </section>
      </template>
    </ResultSet>

    <!-- Status badges -->
    <div class="badges">
      <section>
        <h2>🏁 Finished</h2>
        <div class="badge-row">
          <ResultSet :url="hubUrl" queryId="race-to-goal" :sortBy="x => x.name">
            <template #default="{ item }">
              <span class="badge badge--finish">{{ item.name }}</span>
            </template>
          </ResultSet>
        </div>
      </section>

      <section>
        <h2>😟 Behind pace</h2>
        <div class="badge-row">
          <ResultSet :url="hubUrl" queryId="behind-pace" :sortBy="x => x.name">
            <template #default="{ item }">
              <span class="badge badge--behind">{{ item.name }}</span>
            </template>
          </ResultSet>
        </div>
      </section>
    </div>

    <!-- Leaderboard -->
    <table>
      <thead>
        <tr><th>#</th><th>Name</th><th>Steps</th></tr>
      </thead>
      <tbody>
        <ResultSet :url="hubUrl" queryId="new-leader" :sortBy="x => -x.total">
          <template #default="{ item, index }">
            <tr>
              <td>{{ index + 1 }}</td>
              <td>{{ item.name }}</td>
              <td>{{ item.total.toLocaleString() }}</td>
            </tr>
          </template>
        </ResultSet>
      </tbody>
    </table>
  </main>
</template>

<style scoped>
main { max-width: 32rem; margin: 2rem auto; font-family: system-ui, sans-serif; }
.progress { margin-bottom: 1.5rem; }
.progress__label { display: flex; justify-content: space-between; font-size: 0.9rem; margin-bottom: 0.25rem; }
.progress progress { width: 100%; height: 1rem; }

.badges { display: flex; gap: 2rem; margin-bottom: 1.5rem; }
.badges h2 { font-size: 0.9rem; margin: 0 0 0.5rem; color: #555; }
.badge-row { display: flex; flex-wrap: wrap; gap: 0.4rem; min-height: 1.6rem; }
.badge { padding: 0.15rem 0.6rem; border-radius: 999px; font-size: 0.85rem; }
.badge--finish { background: #e6f4ea; color: #137333; }
.badge--behind { background: #fce8e6; color: #c5221f; }

table { width: 100%; border-collapse: collapse; }
th, td { padding: 0.5rem 0.75rem; text-align: left; border-bottom: 1px solid #ddd; }
th:last-child, td:last-child { text-align: right; font-variant-numeric: tabular-nums; }

.status { padding: 0.15rem 0.6rem; border-radius: 999px; font-size: 0.8rem; text-transform: capitalize; }
.status--idle { background: #eee; color: #555; }
.status--running { background: #e6f4ea; color: #137333; }
.status--finished { background: #fef7e0; color: #8a6d00; }
</style>