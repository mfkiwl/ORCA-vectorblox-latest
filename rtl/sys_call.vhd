library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.constants_pkg.all;

entity system_calls is
  generic (
    REGISTER_SIZE   : natural;
    COUNTER_LENGTH  : natural;
    POWER_OPTIMIZED : boolean;

    INTERRUPT_VECTOR : std_logic_vector(31 downto 0);

    ENABLE_EXCEPTIONS     : boolean;
    ENABLE_EXT_INTERRUPTS : natural range 0 to 1;
    NUM_EXT_INTERRUPTS    : positive range 1 to 32;

    HAS_ICACHE : boolean;
    HAS_DCACHE : boolean
    );
  port (
    clk   : in std_logic;
    reset : in std_logic;

    global_interrupts : in std_logic_vector(NUM_EXT_INTERRUPTS-1 downto 0);
    core_idle         : in std_logic;
    memory_idle       : in std_logic;
    program_counter   : in unsigned(REGISTER_SIZE-1 downto 0);

    to_syscall_valid   : in  std_logic;
    current_pc         : in  unsigned(REGISTER_SIZE-1 downto 0);
    instruction        : in  std_logic_vector(INSTRUCTION_SIZE-1 downto 0);
    rs1_data           : in  std_logic_vector(REGISTER_SIZE-1 downto 0);
    from_syscall_ready : out std_logic;

    from_syscall_valid : out std_logic;
    from_syscall_data  : out std_logic_vector(REGISTER_SIZE-1 downto 0);

    to_pc_correction_data    : out unsigned(REGISTER_SIZE-1 downto 0);
    to_pc_correction_valid   : out std_logic;
    from_pc_correction_ready : in  std_logic;

    from_icache_control_ready : in     std_logic;
    to_icache_control_valid   : buffer std_logic;
    to_icache_control_command : out    cache_control_command;

    from_dcache_control_ready : in     std_logic;
    to_dcache_control_valid   : buffer std_logic;
    to_dcache_control_command : out    cache_control_command;

    interrupt_pending : buffer std_logic
    );
end entity system_calls;

architecture rtl of system_calls is
  component instruction_legal is
    generic (
      check_legal_instructions : boolean
      );
    port (
      instruction : in  std_logic_vector(instruction_size-1 downto 0);
      legal       : out std_logic
      );
  end component;

  -- CSR signals. These are initialized to zero so that if any bits are never
  -- assigned, they act like constants.
  signal mstatus  : std_logic_vector(REGISTER_SIZE-1 downto 0) := (others => '0');
  signal mepc     : std_logic_vector(REGISTER_SIZE-1 downto 0) := (others => '0');
  signal mcause   : std_logic_vector(REGISTER_SIZE-1 downto 0) := (others => '0');
  signal mbadaddr : std_logic_vector(REGISTER_SIZE-1 downto 0) := (others => '0');
  signal mtime    : std_logic_vector(REGISTER_SIZE-1 downto 0) := (others => '0');
  signal mtimeh   : std_logic_vector(REGISTER_SIZE-1 downto 0) := (others => '0');
  signal meimask  : std_logic_vector(REGISTER_SIZE-1 downto 0) := (others => '0');
  signal meipend  : std_logic_vector(REGISTER_SIZE-1 downto 0) := (others => '0');
  signal mcache   : std_logic_vector(REGISTER_SIZE-1 downto 0) := (others => '0');

  alias csr_select is instruction(CSR_ADDRESS'range);
  alias func3 is instruction(INSTR_FUNC3'range);
  alias imm is instruction(CSR_ZIMM'range);

  alias bit_sel        : std_logic_vector(REGISTER_SIZE-1 downto 0) is rs1_data;
  signal csr_read_val  : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal csr_write_val : std_logic_vector(REGISTER_SIZE-1 downto 0);

  signal legal_instr : std_logic;

  signal was_mret      : std_logic;
  signal was_illegal   : std_logic;
  signal was_fence_i   : std_logic;
  signal next_fence_pc : unsigned(REGISTER_SIZE-1 downto 0);

  signal interrupt_pc_correction_valid : std_logic;

  signal time_counter : unsigned(63 downto 0);
begin
  instr_check : instruction_legal
    generic map (
      check_legal_instructions => ENABLE_EXCEPTIONS
      )
    port map (
      instruction => instruction,
      legal       => legal_instr
      );

  -- Process for the timer counter.
  process(clk)
  begin
    if rising_edge(clk) then
      time_counter <= time_counter + 1;
      if reset = '1' then
        time_counter <= (others => '0');
      end if;
    end if;
  end process;

  mtime  <= std_logic_vector(time_counter(REGISTER_SIZE - 1 downto 0)) when COUNTER_LENGTH /= 0 else (others => '0');
  mtimeh <= std_logic_vector(time_counter(time_counter'left downto time_counter'left-REGISTER_SIZE+1))
            when REGISTER_SIZE = 32 and COUNTER_LENGTH = 64 else (others => '0');

  with csr_select select
    csr_read_val <=
    mstatus         when CSR_MSTATUS,
    mepc            when CSR_MEPC,
    mcause          when CSR_MCAUSE,
    mbadaddr        when CSR_MBADADDR,
    meimask         when CSR_MEIMASK,
    meipend         when CSR_MEIPEND,
    mtime           when CSR_MTIME,
    mtimeh          when CSR_MTIMEH,
    mtime           when CSR_UTIME,
    mtimeh          when CSR_UTIMEH,
    mcache          when CSR_MCACHE,
    (others => '0') when others;

  with func3 select
    csr_write_val <=
    rs1_data
    when CSRRW_FUNC3,
    csr_read_val or bit_sel
    when CSRRS_FUNC3,
    csr_read_val(31 downto 5) & (csr_read_val(CSR_ZIMM'length-1 downto 0) or imm)
    when CSRRSI_FUNC3,
    csr_read_val and (not bit_sel)
    when CSRRC_FUNC3,
    csr_read_val(31 downto 5) & (csr_read_val(CSR_ZIMM'length-1 downto 0) and (not imm))
    when CSRRCI_FUNC3,
    csr_read_val
    when others;

  --Sleep CSR is for power optimized versions only; costs area and fmax otherwise
  from_syscall_ready <= '0' when POWER_OPTIMIZED and (instruction(MAJOR_OP'range) = SYSTEM_OP and
                                                      csr_select = CSR_SLEEP and
                                                      csr_write_val /= mtime) else '1';


  exceptions_gen : if ENABLE_EXCEPTIONS generate
    process(clk)
    begin
      if rising_edge(clk) then
        --Hold pc_correction causing signals until they have been processed
        if from_pc_correction_ready = '1' then
          was_mret    <= '0';
          was_illegal <= '0';
        end if;

        if to_syscall_valid = '1' then
          if legal_instr /= '1' then
            -----------------------------------------------------------------------------
            -- Handle Illegal Instructions
            -----------------------------------------------------------------------------
            mstatus(CSR_MSTATUS_MIE)  <= '0';
            mstatus(CSR_MSTATUS_MPIE) <= mstatus(CSR_MSTATUS_MIE);
            mcause                    <= std_logic_vector(to_unsigned(CSR_MCAUSE_ILLEGAL, mcause'length));
            mepc                      <= std_logic_vector(current_pc);
            was_illegal               <= '1';
          elsif instruction(MAJOR_OP'range) = SYSTEM_OP then
            if func3 /= "000" then
              -----------------------------------------------------------------------------
              -- CSR Read/Write
              -----------------------------------------------------------------------------
              case csr_select is
                when CSR_MSTATUS =>
                  -- Only 2 bits are writeable.
                  mstatus(CSR_MSTATUS_MIE)  <= csr_write_val(CSR_MSTATUS_MIE);
                  mstatus(CSR_MSTATUS_MPIE) <= csr_write_val(CSR_MSTATUS_MPIE);
                when CSR_MEPC =>
                  mepc <= csr_write_val;
                when CSR_MCAUSE =>
                  mcause <= csr_write_val;
                when CSR_MBADADDR =>
                  mbadaddr <= csr_write_val;
                when CSR_MEIMASK =>
                  meimask <= csr_write_val;
                --Note that meipend is read-only
                when others => null;
              end case;
            elsif instruction(SYSTEM_NOT_CSR'range) = SYSTEM_NOT_CSR then
              -----------------------------------------------------------------------------
              -- Other System Instructions (mret)
              -----------------------------------------------------------------------------
              if instruction(31 downto 30) = "00" and instruction(27 downto 20) = "00000010" then
                -- We only have one privilege level (M), so treat all [USHM]RET instructions
                -- as the same.
                mstatus(CSR_MSTATUS_MIE)  <= mstatus(CSR_MSTATUS_MPIE);
                mstatus(CSR_MSTATUS_MPIE) <= '0';
                was_mret                  <= '1';
              end if;
            end if;
          end if;
        end if;

        if from_pc_correction_ready = '1' then
          interrupt_pc_correction_valid <= '0';
        end if;

        if interrupt_pending = '1' and core_idle = '1' then
          interrupt_pc_correction_valid <= '1';

          -- Latch in mepc the cycle before interrupt_pc_correction_valid goes high.
          -- When interrupt_pc_correction_valid goes high, the next_pc of the instruction fetch will
          -- be corrected to the interrupt reset vector.
          mepc                      <= std_logic_vector(program_counter);
          mstatus(CSR_MSTATUS_MIE)  <= '0';
          mstatus(CSR_MSTATUS_MPIE) <= '1';
          mcause(mcause'left)       <= '1';
          mcause(3 downto 0)        <= std_logic_vector(to_unsigned(CSR_MCAUSE_MECALL, 4));
        end if;

        if reset = '1' then
          was_mret                      <= '0';
          was_illegal                   <= '0';
          interrupt_pc_correction_valid <= '0';
          --Note that meipend is read-only
          mstatus(CSR_MSTATUS_MIE)      <= '0';
          mstatus(CSR_MSTATUS_MPIE)     <= '0';
          mepc                          <= (others => '0');
          mcause                        <= (others => '0');
          meimask                       <= (others => '0');
        end if;
      end if;
    end process;
    mstatus(REGISTER_SIZE-1 downto CSR_MSTATUS_MPIE+1)   <= (others => '0');
    mstatus(CSR_MSTATUS_MPIE-1 downto CSR_MSTATUS_MIE+1) <= (others => '0');
    mstatus(CSR_MSTATUS_MIE-1 downto 0)                  <= (others => '0');
  end generate exceptions_gen;
  no_exceptions_gen : if not ENABLE_EXCEPTIONS generate
    was_mret                      <= '0';
    was_illegal                   <= '0';
    interrupt_pc_correction_valid <= '0';
    mstatus                       <= (others => '0');
    mepc                          <= (others => '0');
    mcause                        <= (others => '0');
    meimask                       <= (others => '0');
  end generate no_exceptions_gen;

  has_icache_gen : if HAS_ICACHE generate
    process(clk)
    begin
      if rising_edge(clk) then
        if to_syscall_valid = '1' then
          if legal_instr = '1' then
            if instruction(MAJOR_OP'range) = SYSTEM_OP then
              if func3 /= "000" then
                -----------------------------------------------------------------------------
                -- CSR Read/Write
                -----------------------------------------------------------------------------
                if csr_select = CSR_MCACHE then
                  mcache(CSR_MCACHE_IENABLE) <= csr_read_val(CSR_MCACHE_IENABLE);
                end if;
              end if;
            end if;
          end if;
        end if;

        if reset = '1' then
          mcache(CSR_MCACHE_IENABLE) <= '0';
        end if;
      end if;
    end process;
  end generate has_icache_gen;
  no_icache_gen : if not HAS_ICACHE generate
    mcache(CSR_MCACHE_IENABLE) <= '0';
  end generate no_icache_gen;
  has_dcache_gen : if HAS_DCACHE generate
    process(clk)
    begin
      if rising_edge(clk) then
        if to_syscall_valid = '1' then
          if legal_instr = '1' then
            if instruction(MAJOR_OP'range) = SYSTEM_OP then
              if func3 /= "000" then
                -----------------------------------------------------------------------------
                -- CSR Read/Write
                -----------------------------------------------------------------------------
                if csr_select = CSR_MCACHE then
                  mcache(CSR_MCACHE_DENABLE) <= csr_read_val(CSR_MCACHE_DENABLE);
                end if;
              end if;
            end if;
          end if;
        end if;

        if reset = '1' then
          mcache(CSR_MCACHE_DENABLE) <= '0';
        end if;
      end if;
    end process;
  end generate has_dcache_gen;
  no_dcache_gen : if not HAS_DCACHE generate
    mcache(CSR_MCACHE_DENABLE) <= '0';
  end generate no_dcache_gen;
  mcache(REGISTER_SIZE-1 downto CSR_MCACHE_DENABLE+1) <= (others => '0');

  process(clk)
  begin
    if rising_edge(clk) then
      from_syscall_valid <= '0';
      from_syscall_data  <= csr_read_val;

      --Hold pc_correction causing signals until they have been processed
      if from_pc_correction_ready = '1' then

        --On FENCE.I hold the PC correction until all pending writebacks have
        --occurred and the ICache is flushed (from_icache_control_ready is
        --hardwired to '1' when no ICache is present).
        if memory_idle = '1' and (from_icache_control_ready = '1' or to_icache_control_valid = '0') then
          was_fence_i <= '0';
        end if;
      end if;

      if from_icache_control_ready = '1' then
        to_icache_control_valid <= '0';
      end if;

      if to_syscall_valid = '1' then
        next_fence_pc <= unsigned(current_pc) + to_unsigned(4, next_fence_pc'length);

        if HAS_ICACHE then
          if csr_read_val(CSR_MCACHE_IENABLE) = '1' then
            to_icache_control_command <= ENABLE;
          else
            to_icache_control_command <= DISABLE;
          end if;
        end if;
        if HAS_DCACHE then
          if csr_read_val(CSR_MCACHE_DENABLE) = '1' then
            to_dcache_control_command <= ENABLE;
          else
            to_dcache_control_command <= DISABLE;
          end if;
        end if;

        if legal_instr = '1' then
          if instruction(MAJOR_OP'range) = SYSTEM_OP then
            if func3 /= "000" then
              -----------------------------------------------------------------------------
              -- CSR Read/Write
              -----------------------------------------------------------------------------
              if (not POWER_OPTIMIZED) or (csr_select /= CSR_SLEEP) then
                from_syscall_valid <= '1';
              end if;

              --Changing cacheability does a FENCE.I as a form of backpressure
              --(no instructions fetched/executing until cacheability change is
              --done).
              if csr_select = CSR_MCACHE then
                if HAS_ICACHE then
                  if mcache(CSR_MCACHE_IENABLE) /= csr_read_val(CSR_MCACHE_IENABLE) then
                    was_fence_i             <= '1';
                    to_icache_control_valid <= '1';
                  end if;
                end if;
                if HAS_DCACHE then
                  if mcache(CSR_MCACHE_DENABLE) /= csr_read_val(CSR_MCACHE_DENABLE) then
                    was_fence_i             <= '1';
                    to_dcache_control_valid <= '1';
                  end if;
                end if;
              end if;
            elsif instruction(SYSTEM_NOT_CSR'range) = SYSTEM_NOT_CSR then
              -----------------------------------------------------------------------------
              -- Other System Instructions
              -----------------------------------------------------------------------------
              null;
            end if;
          elsif instruction(MAJOR_OP'range) = FENCE_OP then
            to_icache_control_command <= INVALIDATE;
            to_dcache_control_command <= WRITEBACK;
            -- A FENCE instruction is a NOP.
            -- A FENCE.I instruction is a pipeline flush.
            if instruction(12) = '1' then
              was_fence_i             <= '1';
              to_icache_control_valid <= '1';
              to_dcache_control_valid <= '1';
            end if;
          end if;
        end if;
      end if;

      if reset = '1' then
        was_fence_i             <= '0';
        to_icache_control_valid <= '0';
        to_dcache_control_valid <= '0';
      end if;
    end if;
  end process;

--------------------------------------------------------------------------------
-- Handle Global Interrupts
--
-- If interrupt is pending and enabled, slip the pipeline. This is done by
-- sending the interrupt_pending signal to the instruction_fetch.
--
-- Once the pipeline is empty, then correct the PC.
--------------------------------------------------------------------------------
  interrupts_gen : if ENABLE_EXT_INTERRUPTS /= 0 generate
    process(clk)
    begin
      if rising_edge(clk) then
        meipend(NUM_EXT_INTERRUPTS-1 downto 0) <= global_interrupts;
      end if;
    end process;
    not_all_interrupts_gen : if NUM_EXT_INTERRUPTS < REGISTER_SIZE generate
      meipend(REGISTER_SIZE-1 downto NUM_EXT_INTERRUPTS) <= (others => '0');
    end generate not_all_interrupts_gen;
  end generate interrupts_gen;
  no_interrupts_gen : if ENABLE_EXT_INTERRUPTS = 0 generate
    meipend <= (others => '0');
  end generate no_interrupts_gen;
  interrupt_pending <= mstatus(CSR_MSTATUS_MIE) when unsigned(meimask and meipend) /= 0 else '0';

  -- There are several reasons that sys_calls might send a pc correction
  -- global interrupt
  -- illegal instruction
  -- mret instruction
  -- fence.i  (flush pipeline, and start over)
  to_pc_correction_valid <= was_fence_i or was_mret or was_illegal or interrupt_pc_correction_valid;
  to_pc_correction_data <=
    next_fence_pc when was_fence_i = '1' else
    unsigned(INTERRUPT_VECTOR(REGISTER_SIZE-1 downto 0)) when (was_illegal = '1' or
                                                               interrupt_pc_correction_valid = '1') else
    unsigned(mepc) when was_mret = '1' else
    (others => '-');

end architecture rtl;


--------------------------------------------------------------------------------
-- Legal instruction checker
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.constants_pkg.all;

entity instruction_legal is
  generic (
    CHECK_LEGAL_INSTRUCTIONS : boolean
    );
  port (
    instruction : in  std_logic_vector(INSTRUCTION_SIZE-1 downto 0);
    legal       : out std_logic
    );
end entity;

architecture rtl of instruction_legal is
  alias opcode7 is instruction(6 downto 0);
  alias func3 is instruction(INSTR_FUNC3'range);
  alias func7 is instruction(31 downto 25);
  alias csr_num is instruction(SYSTEM_MINOR_OP'range);
begin
  legal <=
    '1' when (CHECK_LEGAL_INSTRUCTIONS = false or
              opcode7 = LUI_OP or
              opcode7 = AUIPC_OP or
              opcode7 = JAL_OP or
              (opcode7 = JALR_OP and func3 = "000") or
              (opcode7 = BRANCH_OP and func3 /= "010" and func3 /= "011") or
              (opcode7 = LOAD_OP and func3 /= "011" and func3 /= "110" and func3 /= "111") or
              (opcode7 = STORE_OP and (func3 = "000" or func3 = "001" or func3 = "010")) or
              opcode7 = ALUI_OP or      -- Does not catch illegal
                                        -- shift amounts
              (opcode7 = ALU_OP and (func7 = ALU_F7 or func7 = MUL_F7 or func7 = SUB_F7))or
              (opcode7 = FENCE_OP) or   -- All fence ops are treated as legal
              (opcode7 = SYSTEM_OP and csr_num /= SYSTEM_ECALL and csr_num /= SYSTEM_EBREAK) or
              opcode7 = LVE_OP) else '0';
end architecture;
