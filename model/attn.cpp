// Bit-accurate fixed-point golden model, C++ reimplementation.
//
// NORMATIVE reference: docs/uarch.md. This file must be BIT-IDENTICAL to
// model/attn.py on every input; model/crosscheck.py proves it. It consumes
// the exp LUT emitted by attn.py (model/exp_lut.hex) so the table has exactly
// one source in the project.
//
// C++ pitfall handled here: integer '/' truncates toward zero, but the spec
// requires floor semantics on negatives. All rounding goes through floordiv().
//
// Usage: attn_cpp <exp_lut.hex> <stimulus.txt> <output.txt>
//   stimulus: "N D" then N*D ints for Q, N*D for K, N*D for V (Q1.6 raw,
//   whitespace separated). Output: N lines of D ints (Q1.6 raw).

#include <cassert>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {

// ---- Normative constants (docs/uarch.md sections 1-3) ----------------------
constexpr int kDDim = 16;
constexpr int kDShift = 2;      // log2(sqrt(D))
constexpr int kNMax = 256;
constexpr int kWFrac = 15;      // UQ1.15
constexpr int kLutSize = 1024;
constexpr int kLutStepShift = 4;          // Q5.10 diff -> 2^-6 grid
constexpr int64_t kLutDomainRaw = -16384; // -16.0 in Q5.10
constexpr int64_t kMInit = -32768;
constexpr int64_t kExpOne = 32768;

// ---- Rounding helpers (docs/uarch.md section 4) -----------------------------
int64_t floordiv(int64_t a, int64_t b) {
  int64_t q = a / b, r = a % b;
  if (r != 0 && ((r < 0) != (b < 0))) --q;
  return q;
}

// Round-half-up arithmetic right shift: floor(x/2^k + 1/2).
int64_t rshr(int64_t x, int k) {
  return floordiv(x + (int64_t{1} << (k - 1)), int64_t{1} << k);
}

// Round-half-up division a/b, b > 0.
int64_t divr(int64_t a, int64_t b) { return floordiv(2 * a + b, 2 * b); }

int64_t sat(int64_t x, int64_t lo, int64_t hi) {
  return x < lo ? lo : (x > hi ? hi : x);
}

int lut_index(int64_t d_raw) {
  assert(d_raw <= 0);
  if (d_raw < kLutDomainRaw) d_raw = kLutDomainRaw;
  int64_t idx = (-d_raw + 8) >> kLutStepShift;  // operand is non-negative
  return static_cast<int>(idx < kLutSize ? idx : kLutSize - 1);
}

// ---- Model class (OOP per the build sheet; holds the LUT and config) --------
class AttnModel {
 public:
  explicit AttnModel(std::vector<int> lut) : lut_(std::move(lut)) {
    assert(static_cast<int>(lut_.size()) == kLutSize);
    assert(lut_[0] == kExpOne);
  }

  // Streaming attention per docs/uarch.md section 6. q,k,v are N x D of
  // Q1.6 raw ints in [-128, 127]; returns N x D of Q1.6 raw ints.
  std::vector<std::vector<int>> run(const std::vector<std::vector<int>>& q,
                                    const std::vector<std::vector<int>>& k,
                                    const std::vector<std::vector<int>>& v) const {
    const int n = static_cast<int>(q.size());
    const int d = static_cast<int>(q[0].size());
    assert(1 <= n && n <= kNMax);
    assert(d == kDDim);

    std::vector<std::vector<int>> out;
    out.reserve(n);
    for (int i = 0; i < n; ++i) {
      int64_t m = kMInit;
      int64_t l = 0;
      std::vector<int64_t> acc(d, 0);
      for (int j = 0; j < n; ++j) {
        // MAC: exact 24-bit dot product (SACC, Q11.12)
        int64_t sacc = 0;
        for (int dd = 0; dd < d; ++dd) sacc += int64_t{1} * q[i][dd] * k[j][dd];
        assert(-(int64_t{1} << 23) <= sacc && sacc < (int64_t{1} << 23));

        // score: one rounding, frac 12->10 plus /sqrt(D) (rounding site 1)
        int64_t s = sat(rshr(sacc, 2 + kDShift), -32768, 32767);

        // online softmax step (rounding sites 2, 3, 4)
        int64_t m_new = (m >= s) ? m : s;
        int64_t r = lut_[lut_index(m - m_new)];
        int64_t w = lut_[lut_index(s - m_new)];
        l = rshr(l * r, kWFrac) + w;
        assert(0 <= l && l < (int64_t{1} << 24));
        for (int dd = 0; dd < d; ++dd) {
          acc[dd] = rshr(acc[dd] * r, kWFrac) + w * v[j][dd];
          assert(-(int64_t{1} << 31) <= acc[dd] && acc[dd] < (int64_t{1} << 31));
        }
        m = m_new;
      }

      // output: scale-cancelling division (rounding site 5), defensive sat
      assert(l >= kExpOne);
      std::vector<int> row(d);
      for (int dd = 0; dd < d; ++dd)
        row[dd] = static_cast<int>(sat(divr(acc[dd], l), -128, 127));
      out.push_back(std::move(row));
    }
    return out;
  }

 private:
  std::vector<int> lut_;
};

std::vector<int> load_lut_hex(const std::string& path) {
  std::ifstream f(path);
  if (!f) { std::cerr << "cannot open LUT: " << path << "\n"; std::exit(2); }
  std::vector<int> lut;
  std::string line;
  while (std::getline(f, line)) {
    if (line.empty()) continue;
    lut.push_back(static_cast<int>(std::stoul(line, nullptr, 16)));
  }
  if (static_cast<int>(lut.size()) != kLutSize) {
    std::cerr << "LUT has " << lut.size() << " entries, expected " << kLutSize << "\n";
    std::exit(2);
  }
  return lut;
}

std::vector<std::vector<int>> read_matrix(std::ifstream& f, int n, int d) {
  std::vector<std::vector<int>> mat(n, std::vector<int>(d));
  for (int i = 0; i < n; ++i)
    for (int j = 0; j < d; ++j) {
      if (!(f >> mat[i][j])) { std::cerr << "stimulus truncated\n"; std::exit(2); }
      if (mat[i][j] < -128 || mat[i][j] > 127) {
        std::cerr << "input " << mat[i][j] << " outside int8\n";
        std::exit(2);
      }
    }
  return mat;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 4) {
    std::cerr << "usage: attn_cpp <exp_lut.hex> <stimulus.txt> <output.txt>\n";
    return 2;
  }
  AttnModel model(load_lut_hex(argv[1]));

  std::ifstream f(argv[2]);
  if (!f) { std::cerr << "cannot open stimulus: " << argv[2] << "\n"; return 2; }
  int n = 0, d = 0;
  f >> n >> d;
  const auto q = read_matrix(f, n, d);
  const auto k = read_matrix(f, n, d);
  const auto v = read_matrix(f, n, d);

  const auto out = model.run(q, k, v);

  std::ofstream fo(argv[3]);
  if (!fo) { std::cerr << "cannot open output: " << argv[3] << "\n"; return 2; }
  for (const auto& row : out) {
    for (size_t j = 0; j < row.size(); ++j)
      fo << row[j] << (j + 1 < row.size() ? ' ' : '\n');
  }
  return 0;
}
