library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
--use IEEE.std_logic_arith.all;
use IEEE.NUMERIC_STD.ALL;
use IEEE.std_logic_unsigned.all;
 
entity fir_filter is
    generic(
        FILTER_TAPS : integer := 16; -- Order of filter(number of samples and coefficients
        INPUT_WIDTH : integer := 8;
        COEFF_WIDTH : integer := 8; 
        OUTPUT_WIDTH : integer := 8; -- This should be < (Input+Coeff width-1) Basically how many bits of the accumulator you want.
        ADDR_WIDTH : integer := 8 -- Addr of coefficient blockram
    );
    Port ( 
        -- Filter specific
        clk : in STD_LOGIC; -- System clk
        reset_n : in std_logic; -- async active low reset
        data_i  : in STD_LOGIC_Vector(INPUT_WIDTH-1 downto 0); -- From sensor or whatever
        data_o  : out STD_LOGIC_Vector(INPUT_WIDTH-1 downto 0);
        new_data: in std_logic; -- Notifies system of incoming data. Is Handshake necessary?
        
        -- coefficient block access
        coeff_read_data_rdy_filter : in std_logic;
        coeff_read_addr_filter: out std_logic_vector(ADDR_WIDTH-1 downto 0);
        coeff_read_data_filter: in std_logic_vector(COEFF_WIDTH-1 downto 0);
        coeff_read_req_filter : out std_logic
        
    );
end fir_filter;
 
architecture Behavioral of fir_filter is
    -- Filter specific signals 
    
    type input_registers is array(0 to FILTER_TAPS-1) of signed(INPUT_WIDTH-1+1 downto 0); -- Creates array of Z^-1 blocks. +1 for parity bit
    signal delay_line  : input_registers := (others=>(others=>'0'));
 
    type coefficients is array (0 to FILTER_TAPS-1) of signed(COEFF_WIDTH-1+1 downto 0); -- +1 for parity bit
    signal coeff_registers: coefficients := ( -- contents here must match the .coe bram init file
    "000000101","000001001","000001100","000010001",
    "000010100","000011000","000011101","000100001",
    "000100100","000101000","000101101","000110000",
    "000110101","000111001","000111100","001000001");
    
     
    type filter_states is (idle, active); -- Add more as needed 
    signal curr_filter_state : filter_states := idle;
 
    signal counter : integer range 0 to FILTER_TAPS-1 := FILTER_TAPS-1; -- keeps track of which tap we are on
    signal output       : signed(INPUT_WIDTH+COEFF_WIDTH-1 downto 0) := (others=>'0');
    signal accumulator  : signed(INPUT_WIDTH+COEFF_WIDTH-1 downto 0) := (others=>'0');
    
    -- Signals for refreshing coefficient contents.
    type refresh_states is (idle,fetch_next_coeff,check_parity,req_coeff,wait_data_rdy,append_parity,refresh,ERROR);
    signal refresh_state : refresh_states := idle;
    signal expt_state : refresh_states := idle;
    
    attribute fsm_encoding : string;

    attribute fsm_encoding of curr_filter_state : signal is "one_hot";
    attribute fsm_encoding of refresh_state : signal is "one_hot";
    attribute fsm_encoding of expt_state : signal is "one_hot";
    
    signal error_trigger_r : std_logic := '0';
    
    signal refresh_register : std_logic_vector(COEFF_WIDTH-1 downto 0); -- Holds the refreshed coefficient so it can be written to the coeff? Redundant?
    signal refresh_counter : unsigned(ADDR_WIDTH-1 downto 0) := (others => '0'); -- Keeps track of which we are scrubbing
    signal current_coefficient : std_logic_vector(COEFF_WIDTH downto 0) := (others => '0');
    signal coefficient_counter : integer range 0 to FILTER_TAPS-1 := 0;
    signal refresh_parity_bit : std_logic := '0';
    
    signal suspend_filter : std_logic := '0';
    signal coeff_mismatch : std_logic := '0'; -- When coeff mismatch
    
    signal curr_parity_bit : std_logic := '0';
    signal curr_filter_tap_std_vector : std_logic_vector(INPUT_WIDTH-1+1 downto 0) := (others => '0');
    
    
    type dummy_data is array(0 to FILTER_TAPS-1) of signed(INPUT_WIDTH-1 downto 0);
    signal dummy: dummy_data := (
    X"01",X"02",X"03",X"04",
    X"05",X"06",X"07",X"08",
    X"09",X"0a",X"0b",X"0c",
    X"0d",X"0e",X"0f",X"10");
    
    attribute keep : string;
    attribute keep of delay_line : signal is "true";
    attribute keep of coeff_registers : signal is "true";
    attribute keep of curr_filter_state : signal is "true";
    attribute keep of refresh_state : signal is "true";
    attribute keep of expt_state : signal is "true";
    attribute keep of counter : signal is "true";
    attribute keep of output : signal is "true";
    attribute keep of accumulator : signal is "true";
    attribute keep of error_trigger_r : signal is "true";
    attribute keep of refresh_register : signal is "true";
    attribute keep of refresh_counter : signal is "true";
    attribute keep of current_coefficient : signal is "true";
    attribute keep of coefficient_counter : signal is "true";
    attribute keep of refresh_parity_bit : signal is "true";
    attribute keep of suspend_filter : signal is "true";
    attribute keep of curr_parity_bit : signal is "true";
    attribute keep of curr_filter_tap_std_vector : signal is "true";
    attribute keep of dummy : signal is "true";
    
  
begin

    
 
    data_o <= std_logic_vector(output(INPUT_WIDTH+COEFF_WIDTH-2 downto INPUT_WIDTH+COEFF_WIDTH-OUTPUT_WIDTH-1));
 
    process(clk) -- Double check sensitivity list, move counter?
        variable sum_v : signed(INPUT_WIDTH+COEFF_WIDTH-1 downto 0) := (others=>'0'); 
        variable iterator : integer := 0;
    begin
        if(clk'event and clk = '1') then
        case curr_filter_state is
            when idle => 
                --if (new_data = '1') then
                    curr_filter_state <= active;
                --end if;
            when active =>
                if(suspend_filter = '0') then
                    -- Counter
                    if(coeff_mismatch = '0') then
                        if counter > 0 then
                            counter <= counter - 1;
                        else
                            counter <= FILTER_TAPS-1;
                            curr_filter_state <= idle;
                        end if;
                    else
                        coeff_mismatch <= '0';
                    end if;
                
                    -- Verify conents through parity bit.
                    -- If mismatch, shift-the-tap. (but only if counter < FILTER_TAPS-1).
                    -- The final tap at the end of the line(IE delay_line(FILTER_TAPS-1) can remain the same(if it is uncorrupted)
                    -- On filter initialization all values in the delayline are all 0, including the parity bit, which should obviously pass this test.
                    curr_filter_tap_std_vector <= std_logic_vector(unsigned(delay_line(counter))); -- Converts signed to unsigned for easier check of parity (LSB is Parity bit)
                    for i in 1 to curr_filter_tap_std_vector'length-1 loop
                        curr_parity_bit <= curr_parity_bit xor curr_filter_tap_std_vector(i);
                    end loop;
                    -- Now compare
                    if(curr_parity_bit /= curr_filter_tap_std_vector(0)) then
                        -- This code runs if mismatch
                        -- Now shift all taps from delay_line(FILTER_TAPS-1) to delay_line(counter);
                        if(counter = FILTER_TAPS-1) then
                            -- The mismatch was found at the end of the delay_line, we flush its contents
                            delay_line(counter) <= (others => '0');
                        else
                            -- Mismatch found somewhere in the delay line
                            --iterator := counter;
                            for i in 0 to FILTER_TAPS-2 loop -- We do not start at FILTER_TAPS-1 since its the end
                               
                                if(i >= counter) then -- Synth work a round, disgusting
                                    delay_line(i) <= delay_line(i+1); --Update the values with the ones proceeding them in delay line 
                                end if;
                                --iterator := iterator + 1;
                            end loop; -- Final tap is left alone, it keeps its value.
                        end if;
                    end if;
                    -- Reset curr parity bit
                    curr_parity_bit <= '0';
                
                    -- Delay line shifting
                    if counter > 0 then
                        delay_line(counter) <= delay_line(counter-1);
                    else
                        curr_filter_tap_std_vector <= std_logic_vector(unsigned(dummy(counter))) & '0';--data_i & '0'; -- Converts signed to unsigned for easier check of parity (LSB is Parity bit)
                        for i in 1 to curr_filter_tap_std_vector'length-1 loop
                            curr_parity_bit <= curr_parity_bit xor curr_filter_tap_std_vector(i);
                        end loop;
                        delay_line(counter) <= signed(dummy(counter) & curr_parity_bit);--data_i & curr_parity_bit); -- Append parity bit to the end
                    end if;
                    
                    -- Check if coefficients have mismatch
                    current_coefficient <= std_logic_vector(unsigned(coeff_registers(counter)));
                    for i in 1 to current_coefficient'length-1 loop
                        curr_parity_bit <= curr_parity_bit xor current_coefficient(i);
                    end loop;
                    if(curr_parity_bit /= current_coefficient(0)) then
                        coeff_mismatch <= '1';
                    end if;
             
                    -- MAC operations
                    if(coeff_mismatch = '0') then
                        if counter > 0 then
                            sum_v := delay_line(counter)(INPUT_WIDTH-1+1 downto 1)*coeff_registers(counter)(8 downto 1); -- We do math without the LSB(the parity bit)
                            accumulator <= accumulator + sum_v;    
                        else
                            accumulator <= (others=>'0');
                            sum_v := delay_line(counter)(INPUT_WIDTH-1+1 downto 1)*coeff_registers(counter)(8 downto 1);
                            output <= accumulator + sum_v;  
                        end if;
                    end if;
                end if;
            when others =>
                curr_filter_state <= idle;
        end case;
        end if;
    end process;
    
    process(reset_n,clk) begin
        if(reset_n = '0') then
            refresh_state <= idle;
            expt_state <= idle;
            coefficient_counter <= 0;
            refresh_parity_bit <= '0';
            refresh_counter <= (others => '0');
            coeff_read_req_filter <= '0';
            coeff_read_addr_filter <= (others => '0');
            refresh_register <= (others =>'0');
            suspend_filter <= '0';
        elsif(rising_edge(clk)) then
            case(refresh_state) is
                when idle =>
                    -- **********************************************
                    -- There is really nothing to wait for, so we continue
                    -- the continuous refreshing of coefficients
                    -- **********************************************
                    refresh_state <= fetch_next_coeff;
                    expt_state <= fetch_next_coeff;
                    suspend_filter <= '0';
                    
	
                    if(coeff_mismatch = '1') then
                        refresh_state <= req_coeff;
                        suspend_filter <= '1';  -- Badness                  
                    end if;
                    
                    
                when req_coeff =>
                    -- **********************************************
                    -- Put in a request for data from coefficient memory
                    -- We have to wait for our turn and for data to be available
                    -- **********************************************
                    
                    coeff_read_req_filter <= '1';
                    coeff_read_addr_filter <= std_logic_vector(to_unsigned(counter,8)); 
                    refresh_state <= wait_data_rdy;
                    expt_state <= wait_data_rdy;
                    
                    
                when wait_data_rdy =>
                    -- **********************************************
                    -- Since we have a lower prio than scrubber
                    -- We have to wait potentially 6 cycles until rdy
                    -- **********************************************
                    if(coeff_read_data_rdy_filter = '1') then
                        coeff_read_req_filter <= '0';
                        refresh_register <= coeff_read_data_filter;
                        refresh_state <= append_parity;
                        expt_state <= append_parity;
                    else
                        refresh_state <= wait_data_rdy;
                        expt_state <= wait_data_rdy;
                    end if;

                    
                when append_parity =>
                    -- **********************************************
                    -- Add parity bit to data we read. 
                    -- **********************************************
                    for i in 0 to refresh_register'length-1 loop
                        refresh_parity_bit <= refresh_parity_bit xor refresh_register(i);
                    end loop;
                    refresh_state <= refresh;
                    expt_state <= refresh;
                    
                    
                    
                when refresh =>
                    -- **********************************************
                    -- Math is suspended, should be safe to write
                    -- **********************************************
                    coeff_registers(counter) <= signed(refresh_register & refresh_parity_bit);
                    refresh_state <= idle;
                    expt_state <= idle;
                    

                 
				when ERROR =>
					refresh_state <= expt_state;
                    
                when others =>
                    refresh_state <= expt_state;
            end case;
        end if;
    end process;
    
    
    

end Behavioral;