-- mac_unit: VHDL-2008 port of rtl/mac_unit.sv, same contract and widths.
-- `make vhdl-crosscheck` compares both against one golden vector file.
--   a, b : ACT Q1.6 s8; a*b exact s16
--   acc  : SACC Q11.12 s24; no rounding or saturation, no overflow for
--          dot lengths <= 511 (uarch 3.2)
-- Control: rst clears; clr=1,en=1 loads a*b; clr=1,en=0 clears;
-- clr=0,en=1 accumulates; else hold.
-- Not yet simulated.
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
        -- 24-bit addition wraps like the SystemVerilog 24'() cast
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
