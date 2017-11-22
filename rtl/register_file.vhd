library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.constants_pkg.all;

entity register_file is
  generic(
    REGISTER_SIZE         : positive;
    REGISTER_NAME_SIZE    : positive;
    WRITE_FIRST_SUPPORTED : boolean
    );
  port(
    clk         : in std_logic;
    rs1_sel     : in std_logic_vector(REGISTER_NAME_SIZE-1 downto 0);
    rs2_sel     : in std_logic_vector(REGISTER_NAME_SIZE-1 downto 0);
    wb_sel      : in std_logic_vector(REGISTER_NAME_SIZE-1 downto 0);
    wb_data     : in std_logic_vector(REGISTER_SIZE-1 downto 0);
    wb_enable   : in std_logic;

    rs1_data : out std_logic_vector(REGISTER_SIZE-1 downto 0);
    rs2_data : out std_logic_vector(REGISTER_SIZE-1 downto 0)
    );
end;

architecture rtl of register_file is
  type register_vector is array(31 downto 0) of std_logic_vector(REGISTER_SIZE-1 downto 0);

  signal registers : register_vector := (others => (others => '0'));

--These aliases are useful during simulation of software.
  alias ra  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_RA));
  alias sp  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_SP));
  alias gp  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_GP));
  alias tp  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_TP));
  alias t0  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_T0));
  alias t1  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_T1));
  alias t2  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_T2));
  alias s0  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_S0));
  alias s1  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_S1));
  alias a0  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_A0));
  alias a1  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_A1));
  alias a2  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_A2));
  alias a3  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_A3));
  alias a4  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_A4));
  alias a5  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_A5));
  alias a6  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_A6));
  alias a7  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_A7));
  alias s2  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_S2));
  alias s3  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_S3));
  alias s4  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_S4));
  alias s5  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_S5));
  alias s6  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_S6));
  alias s7  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_S7));
  alias s8  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_S8));
  alias s9  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_S9));
  alias s10 : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_S10));
  alias s11 : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_S11));
  alias t3  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_T3));
  alias t4  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_T4));
  alias t5  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_T5));
  alias t6  : std_logic_vector(REGISTER_SIZE-1 downto 0) is registers(to_integer(REGISTER_T6));
begin

  bypass_gen : if not WRITE_FIRST_SUPPORTED generate
    signal out1               : std_logic_vector(REGISTER_SIZE-1 downto 0);
    signal out2               : std_logic_vector(REGISTER_SIZE-1 downto 0);
    signal read_during_write1 : std_logic;
    signal read_during_write2 : std_logic;
    signal wb_data_latched    : std_logic_vector(REGISTER_SIZE-1 downto 0);
  begin
    process (clk) is
    begin
      if rising_edge(clk) then
        out1 <= registers(to_integer(unsigned(rs1_sel)));
        out2 <= registers(to_integer(unsigned(rs2_sel)));
        if wb_enable = '1' then
          registers(to_integer(unsigned(wb_sel))) <= wb_data;
        end if;
      end if;  --rising edge
    end process;


    --read during write logic
    rs1_data <= wb_data_latched when read_during_write1 = '1' else out1;
    rs2_data <= wb_data_latched when read_during_write2 = '1' else out2;
    process(clk) is
    begin
      if rising_edge(clk) then
        read_during_write2 <= '0';
        read_during_write1 <= '0';
        if rs1_sel = wb_sel and wb_enable = '1' then
          read_during_write1 <= '1';
        end if;
        if rs2_sel = wb_sel and wb_enable = '1' then
          read_during_write2 <= '1';
        end if;
        wb_data_latched <= wb_data;
      end if;
    end process;
  end generate bypass_gen;

  write_first_gen : if WRITE_FIRST_SUPPORTED generate
    process (clk) is
      variable registers_variable : register_vector := (others => (others => '0'));
    begin
      if rising_edge(clk) then
        if wb_enable = '1' then
          registers_variable(to_integer(unsigned(wb_sel))) := wb_data;
        end if;
        rs1_data <= registers_variable(to_integer(unsigned(rs1_sel)));
        rs2_data <= registers_variable(to_integer(unsigned(rs2_sel)));
      end if;  --rising edge
    end process;
    process (clk) is
    begin  -- process
      if rising_edge(clk) then          -- rising clock edge
        --Vivado simulator doesn't like tracing variables so this signal
        --duplicates the register_file variable
        if wb_enable = '1' then
          registers(to_integer(unsigned(wb_sel))) <= wb_data;
        end if;
      end if;
    end process;
  end generate write_first_gen;

end architecture;
