-- mac_unit (VHDL-2008 port of rtl/mac_unit.sv, added 2026-09-19, target-
-- scores change 9). Same contract, same widths, same priority, kept in the
-- repo beside the SystemVerilog original; tb/vhdl_mac replays one golden
-- vector file through both and byte-compares the traces (`make
-- vhdl-crosscheck`), which is the only evidence the port is equivalent.
--
-- Formats (normative, docs/uarch.md 3.1/3.2):
--   a, b : ACT, signed Q1.6, 8 bits
--   a*b  : exact signed product, 16 bits
--   acc  : SACC, signed Q11.12, 24 bits; exact accumulation, no rounding,
--          no saturation; overflow impossible for dot lengths <= 511
--
-- Control contract (one cycle, all synchronous):
--   rst          : acc <= 0
--   clr=1, en=1  : acc <= a*b        (start a new dot product, no dead cycle)
--   clr=1, en=0  : acc <= 0
--   clr=0, en=1  : acc <= acc + a*b
--   clr=0, en=0  : hold
--
-- STATUS: never simulated (no GHDL where this was written).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mac_unit is
  port (
    clk : in  std_logic;
    rst : in  std_logic;                      -- synchronous, active-high
    en  : in  std_logic;                      -- accept a*b this cycle
    clr : in  std_logic;                      -- start new accumulation this cycle
    a   : in  std_logic_vector(7 downto 0);   -- ACT Q1.6
    b   : in  std_logic_vector(7 downto 0);   -- ACT Q1.6
    acc : out std_logic_vector(23 downto 0)   -- SACC Q11.12
  );
end entity mac_unit;

architecture rtl of mac_unit is
  signal acc_q : signed(23 downto 0) := (others => '0');
begin
  acc <= std_logic_vector(acc_q);

  process (clk)
    variable prod  : signed(15 downto 0);
    variable base  : signed(23 downto 0);
    variable acc_n : signed(23 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        acc_q <= (others => '0');
      else
        -- exact 16-bit signed product (8s x 8s), sign-extended to 24 bits;
        -- the 24-bit addition wraps exactly like the SystemVerilog 24'() cast
        prod := signed(a) * signed(b);
        if clr = '1' then
          base := (others => '0');
        else
          base := acc_q;
        end if;
        if en = '1' then
          acc_n := base + resize(prod, 24);
        else
          acc_n := base;
        end if;
        acc_q <= acc_n;
      end if;
    end if;
  end process;
end architecture rtl;
