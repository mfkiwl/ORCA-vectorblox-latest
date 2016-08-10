library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;
library work;
use work.rv_components.all;
use work.utils.all;

entity Orca is

  generic (
    REGISTER_SIZE      : integer               := 32;
    RESET_VECTOR       : natural               := 16#00000200#;
    MULTIPLY_ENABLE    : natural range 0 to 1  := 0;
    DIVIDE_ENABLE      : natural range 0 to 1  := 0;
    SHIFTER_MAX_CYCLES : natural               := 1;
    COUNTER_LENGTH     : natural               := 0;
    BRANCH_PREDICTORS  : natural               := 0;
    PIPELINE_STAGES    : natural range 4 to 5  := 5;
    FORWARD_ALU_ONLY   : natural range 0 to 1  := 1;
    MXP_ENABLE         : natural range 0 to 1  := 0;
    NUM_EXT_INTERRUPTS : integer range 2 to 32 := 2);

  port(clk            : in std_logic;
       scratchpad_clk : in std_logic;
       reset          : in std_logic;

       --avalon master bus
       avm_data_address              : out std_logic_vector(REGISTER_SIZE-1 downto 0);
       avm_data_byteenable           : out std_logic_vector(REGISTER_SIZE/8 -1 downto 0);
       avm_data_read                 : out std_logic;
       avm_data_readdata             : in  std_logic_vector(REGISTER_SIZE-1 downto 0) := (others => 'X');
       avm_data_write                : out std_logic;
       avm_data_writedata            : out std_logic_vector(REGISTER_SIZE-1 downto 0);
       avm_data_waitrequest          : in  std_logic                                  := '0';
       avm_data_readdatavalid        : in  std_logic                                  := '0';
       --avalon master bus
       avm_instruction_address       : out std_logic_vector(REGISTER_SIZE-1 downto 0);
       avm_instruction_read          : out std_logic;
       avm_instruction_readdata      : in  std_logic_vector(REGISTER_SIZE-1 downto 0) := (others => 'X');
       avm_instruction_waitrequest   : in  std_logic                                  := '0';
       avm_instruction_readdatavalid : in  std_logic                                  := '0';

       global_interrupts : in std_logic_vector(NUM_EXT_INTERRUPTS-1 downto 0) := (others => '0')
       );

end entity Orca;

architecture rtl of Orca is
  constant REGISTER_NAME_SIZE  : integer := 5;
  constant INSTRUCTION_SIZE    : integer := 32;
  constant SIGN_EXTENSION_SIZE : integer := 20;

  --signals going into fetch
  signal if_stall_in  : std_logic;
  signal if_valid_out : std_logic;

  --signals going into decode
  signal d_instr     : std_logic_vector(INSTRUCTION_SIZE -1 downto 0);
  signal d_pc        : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal d_br_taken  : std_logic;
  signal d_valid     : std_logic;
  signal d_valid_out : std_logic;

  signal wb_data : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal wb_sel  : std_logic_vector(REGISTER_NAME_SIZE-1 downto 0);
  signal wb_en   : std_logic;

  --signals going into execute
  signal e_instr        : std_logic_vector(INSTRUCTION_SIZE -1 downto 0);
  signal e_subseq_instr : std_logic_vector(INSTRUCTION_SIZE -1 downto 0);
  signal e_pc           : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal e_br_taken     : std_logic;
  signal e_valid        : std_logic;
  signal e_readvalid    : std_logic;
  signal pipeline_empty : std_logic;

  signal execute_stalled : std_logic;
  signal rs1_data        : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal rs2_data        : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal sign_extension  : std_logic_vector(REGISTER_SIZE-12-1 downto 0);

  signal pipeline_flush : std_logic;

  signal data_address    : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal data_byte_en    : std_logic_vector(REGISTER_SIZE/8 -1 downto 0);
  signal data_write_en   : std_logic;
  signal data_read_en    : std_logic;
  signal data_write_data : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal data_read_data  : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal data_wait       : std_logic;

  signal instr_address : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal instr_data    : std_logic_vector(INSTRUCTION_SIZE-1 downto 0);

  signal instr_read_wait : std_logic;
  signal instr_read_en   : std_logic;
  signal instr_readvalid : std_logic;

  signal instruction_fetch_pc : std_logic_vector(REGISTER_SIZE-1 downto 0);

  -- Data splitter signals
  signal data_sel      : std_logic;
  signal data_sel_prev : std_logic;

  -- Reserved register bus lines
  signal plic_address       : std_logic_vector(7 downto 0);
  signal plic_byteenable    : std_logic_vector(REGISTER_SIZE/8 -1 downto 0);
  signal plic_read          : std_logic;
  signal plic_readdata      : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal plic_response      : std_logic_vector(1 downto 0);
  signal plic_write         : std_logic;
  signal plic_writedata     : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal plic_lock          : std_logic;
  signal plic_waitrequest   : std_logic;
  signal plic_readdatavalid : std_logic;

  -- Interrupt lines
  signal mtime             : std_logic_vector(63 downto 0);
  signal mip_mtip          : std_logic;
  signal mip_msip          : std_logic;
  signal mip_meip          : std_logic;
  signal interrupt_pending : std_logic;

  signal branch_pred : std_logic_vector(REGISTER_SIZE*2 + 3-1 downto 0);
begin  -- architecture rtl
  pipeline_flush <= branch_get_flush(branch_pred);

  if_stall_in <= execute_stalled;
  instr_fetch : component instruction_fetch
    generic map (
      REGISTER_SIZE     => REGISTER_SIZE,
      INSTRUCTION_SIZE  => INSTRUCTION_SIZE,
      RESET_VECTOR      => RESET_VECTOR,
      BRANCH_PREDICTORS => BRANCH_PREDICTORS)
    port map (
      clk         => clk,
      reset       => reset,
      stall       => if_stall_in,
      branch_pred => branch_pred,

      instr_out            => d_instr,
      pc_out               => d_pc,
      br_taken             => d_br_taken,
      valid_instr_out      => if_valid_out,
      read_address         => instr_address,
      read_en              => instr_read_en,
      read_data            => instr_data,
      read_datavalid       => instr_readvalid,
      read_wait            => instr_read_wait,
      interrupt_pending    => interrupt_pending);

  d_valid <= if_valid_out and not pipeline_flush;

  D : component decode
    generic map(
      REGISTER_SIZE       => REGISTER_SIZE,
      REGISTER_NAME_SIZE  => REGISTER_NAME_SIZE,
      INSTRUCTION_SIZE    => INSTRUCTION_SIZE,
      SIGN_EXTENSION_SIZE => SIGN_EXTENSION_SIZE,
      PIPELINE_STAGES     => PIPELINE_STAGES-3)
    port map(
      clk            => clk,
      reset          => reset,
      stall          => execute_stalled,
      flush          => pipeline_flush,
      instruction    => d_instr,
      valid_input    => d_valid,
      --writeback signals
      wb_sel         => wb_sel,
      wb_data        => wb_data,
      wb_enable      => wb_en,
      --output signals
      rs1_data       => rs1_data,
      rs2_data       => rs2_data,
      sign_extension => sign_extension,
      --inputs just for carrying to next pipeline stage
      br_taken_in    => d_br_taken,
      pc_curr_in     => d_pc,
      br_taken_out   => e_br_taken,
      pc_curr_out    => e_pc,
      instr_out      => e_instr,
      subseq_instr   => e_subseq_instr,
      valid_output   => d_valid_out);

  e_valid        <= d_valid_out and not pipeline_flush;
  -- The pipeline_empty signal means that all stages of the pipeline are finished with
  -- their current instruction, and bubbles have fully propagated through the pipeline.
  pipeline_empty <= ((not if_valid_out) and (not d_valid_out) and (not execute_stalled));
  X : component execute
    generic map (
      REGISTER_SIZE       => REGISTER_SIZE,
      REGISTER_NAME_SIZE  => REGISTER_NAME_SIZE,
      INSTRUCTION_SIZE    => INSTRUCTION_SIZE,
      SIGN_EXTENSION_SIZE => SIGN_EXTENSION_SIZE,
      RESET_VECTOR        => RESET_VECTOR,
      MULTIPLY_ENABLE     => MULTIPLY_ENABLE = 1,
      DIVIDE_ENABLE       => DIVIDE_ENABLE = 1,
      SHIFTER_MAX_CYCLES  => SHIFTER_MAX_CYCLES,
      COUNTER_LENGTH      => COUNTER_LENGTH,
      FORWARD_ALU_ONLY    => FORWARD_ALU_ONLY = 1,
      MXP_ENABLE          => MXP_ENABLE = 1)
    port map (
      clk            => clk,
      scratchpad_clk => scratchpad_clk,
      reset          => reset,
      valid_input    => e_valid,
      br_taken_in    => e_br_taken,
      pc_current     => e_pc,
      instruction    => e_instr,
      subseq_instr   => e_subseq_instr,
      rs1_data       => rs1_data,
      rs2_data       => rs2_data,
      sign_extension => sign_extension,
      wb_sel         => wb_sel,
      wb_data        => wb_data,
      wb_en          => wb_en,
      branch_pred    => branch_pred,

      stall_pipeline => execute_stalled,
      pipeline_empty => pipeline_empty,

      --Memory bus
      address     => data_address,
      byte_en     => data_byte_en,
      write_en    => data_write_en,
      read_en     => data_read_en,
      writedata  => data_write_data,
      readdata   => data_read_data,
      waitrequest => data_wait,
      datavalid   => e_readvalid,

      -- Interrupt lines
      mtime_i              => mtime,
      mip_mtip_i           => mip_mtip,
      mip_msip_i           => mip_msip,
      mip_meip_i           => mip_meip,
      interrupt_pending_o  => interrupt_pending,
      instruction_fetch_pc => d_pc);


  interrupt_controller : component plic
    generic map (
      REGISTER_SIZE => REGISTER_SIZE,
      NUM_EXT_INTERRUPTS => NUM_EXT_INTERRUPTS)
    port map (
      clk   => clk,
      reset => reset,

      global_interrupts => global_interrupts,

      mtime_o    => mtime,
      mip_mtip_o => mip_mtip,
      mip_msip_o => mip_msip,
      mip_meip_o => mip_meip,

      plic_address       => plic_address,
      plic_byteenable    => plic_byteenable,
      plic_read          => plic_read,
      plic_readdata      => plic_readdata,
      plic_response      => plic_response,
      plic_write         => plic_write,
      plic_writedata     => plic_writedata,
      plic_lock          => plic_lock,
      plic_waitrequest   => plic_waitrequest,
      plic_readdatavalid => plic_readdatavalid);

  -- Handle arbitration between the bus and the PLIC
  data_sel <= '1' when unsigned(data_address) >= X"100"
              else '0';

  process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        data_sel_prev <= '0';
      elsif data_read_en = '1' and data_wait = '0' then
        data_sel_prev <= data_sel;
      end if;
    end if;
  end process;

  plic_address    <= data_address(7 downto 0) when data_sel = '0' else (others => '0');
  plic_byteenable <= data_byte_en             when data_sel = '0' else (others => '0');
  plic_read       <= data_read_en             when data_sel = '0' else '0';
  plic_write      <= data_write_en            when data_sel = '0' else '0';
  plic_writedata  <= data_write_data          when data_sel = '0' else (others => '0');
  plic_lock       <= '0';

  avm_data_address    <= data_address    when data_sel = '1' else (others => '0');
  avm_data_byteenable <= data_byte_en    when data_sel = '1' else (others => '0');
  avm_data_read       <= data_read_en    when data_sel = '1' else '0';
  avm_data_write      <= data_write_en   when data_sel = '1' else '0';
  avm_data_writedata  <= data_write_data when data_sel = '1' else (others => '0');

  data_wait <= plic_waitrequest when data_sel = '0' else avm_data_waitrequest;

  data_read_data <= plic_readdata      when data_sel_prev = '0' else avm_data_readdata;
  e_readvalid    <= plic_readdatavalid when data_sel_prev = '0' else avm_data_readdatavalid;

--  data_wait      <= '0' when data_sel = '0' else avm_data_waitrequest;
--  data_read_data <= (others => '0') when data_sel_prev = '0' else avm_data_readdata;
--  e_readvalid    <= '1' when data_sel_prev = '0' else avm_data_readdatavalid;

  avm_instruction_address <= instr_address;
  avm_instruction_read    <= instr_read_en;
  instr_data              <= avm_instruction_readdata;
  instr_read_wait         <= avm_instruction_waitrequest;
  instr_readvalid         <= avm_instruction_readdatavalid;

end architecture rtl;
