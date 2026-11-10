// Build and run from the repo root:
//   g++ -std=c++20 -O3 -march=native -o /tmp/pc_bench scripts/pc_bench.cpp && /tmp/pc_bench model/exp_lut.hex
// Times one attention head (N=64, D=16) on this PC's CPU, one core:
//  (a) the bit-exact C++ golden model (same integer math as the accelerator)
//  (b) a plain float32 attention (what software would normally run)
#define main attn_cpp_main
#include "../model/attn.cpp"
#undef main
#include <chrono>
#include <cmath>
#include <random>

static double secs_per_run(auto&& fn, int reps) {
  auto t0 = std::chrono::steady_clock::now();
  for (int i = 0; i < reps; ++i) fn();
  auto t1 = std::chrono::steady_clock::now();
  return std::chrono::duration<double>(t1 - t0).count() / reps;
}

int main(int argc, char** argv) {
  const int n = 64, d = 16;
  AttnModel model(load_lut_hex(argv[1]));
  std::mt19937 rng(1);
  std::uniform_int_distribution<int> u(-128, 127);
  std::vector<std::vector<int>> q(n, std::vector<int>(d)), k = q, v = q;
  for (auto* m : {&q, &k, &v}) for (auto& r : *m) for (auto& x : r) x = u(rng);
  volatile int sink = 0;
  double t_int = secs_per_run([&] { auto o = model.run(q, k, v); sink += o[0][0]; }, 2000);

  std::vector<float> qf(n * d), kf(n * d), vf(n * d), of(n * d), s(n);
  for (int i = 0; i < n * d; ++i) { qf[i] = q[i / d][i % d] / 64.f; kf[i] = k[i / d][i % d] / 64.f; vf[i] = v[i / d][i % d] / 64.f; }
  double t_flt = secs_per_run([&] {
    for (int i = 0; i < n; ++i) {
      float mx = -1e30f;
      for (int j = 0; j < n; ++j) { float a = 0; for (int t = 0; t < d; ++t) a += qf[i * d + t] * kf[j * d + t]; s[j] = a * 0.25f; mx = std::max(mx, s[j]); }
      float l = 0; for (int j = 0; j < n; ++j) { s[j] = std::exp(s[j] - mx); l += s[j]; }
      for (int t = 0; t < d; ++t) { float a = 0; for (int j = 0; j < n; ++j) a += s[j] * vf[j * d + t]; of[i * d + t] = a / l; }
    }
    sink += (int)of[0];
  }, 20000);
  std::printf("pc_bitexact_us %.2f\npc_float_us %.2f\n", t_int * 1e6, t_flt * 1e6);
  return 0;
}
