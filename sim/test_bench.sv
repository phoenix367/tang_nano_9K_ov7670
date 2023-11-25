`include "timescale.v"

module main();

reg clk, reset_n;
wire scl;
wire sda;
wire led_out;
wire screen_vsync;
wire cam_clk;
wire LCD_CLK;
wire LCD_DE;
wire LCD_HYNC;
reg [4:0] LCD_R;
reg [5:0] LCD_G;
reg [4:0] LCD_B;

localparam TARGET_IMAGE_WIDTH = 481;
localparam TARGET_IMAGE_HEIGHT = 273;

// Camera timing parameters
localparam CAM_PIXEL_CLK = 2;
localparam CAM_HREF_CLK = 640 * CAM_PIXEL_CLK;
localparam CAM_LINE_CLK = 784 * CAM_PIXEL_CLK;
localparam CAM_VSYNC_CLK = 3 * CAM_LINE_CLK;
localparam CAM_HREF_DELAY_CLK = 20 * CAM_LINE_CLK;
localparam CAM_FRAME_CLK = 510 * CAM_LINE_CLK;

int fd;
int cam_clock_counter;
int num_frames;

pullup p1(scl); // pullup scl line
pullup p2(sda); // pullup sda line

initial begin
    $display($time, " << Starting the Simulation >>");
    // initially values
    clk = 0;

    // reset system
    reset_n = 1'b1; // negate reset
    #2;
    reset_n = 1'b0; // assert reset
    repeat(1) @(posedge clk);
    reset_n = 1'b1; // negate reset

    $display("status: %t done reset", $time);

    @(posedge clk);
end

parameter SADR    = 7'h21;

always #18.519 clk=~clk;
assign cam_clk = clk & ~led_out;

wire cam_vsync;
wire cam_href;

CameraControl_TOP camera_control(.sys_clk(clk), .sys_rst_n(reset_n), .master_scl(scl), .master_sda(sda),
                                 .led_out(led_out), .video_clk_i(cam_clk), .LCD_SYNC(screen_vsync), 
                                 .LCD_CLK(LCD_CLK), .LCD_DEN(LCD_DE), .LCD_B(LCD_B), .LCD_G(LCD_G), 
                                 .LCD_R(LCD_R), .LCD_HYNC(LCD_HYNC), .v_sync_i(cam_vsync), .h_sync_i(cam_href),
                                 .cam_data_i(8'hA5)
);
// hookup i2c slave model
i2c_slave_model #(SADR) i2c_slave (
    .scl(scl),
    .sda(sda)
);

always @(posedge cam_clk) begin
    if (cam_clock_counter < CAM_FRAME_CLK)
        cam_clock_counter <= #1 cam_clock_counter + 1;
    else
        cam_clock_counter <= #1 0;
end

assign cam_vsync = (cam_clock_counter < CAM_VSYNC_CLK && !led_out) ? 1'b1 : 1'b0;
assign cam_href = (cam_clock_counter >= CAM_HREF_DELAY_CLK && 
                   ((cam_clock_counter - CAM_HREF_DELAY_CLK) % CAM_LINE_CLK) < CAM_HREF_CLK) ? 1'b1 : 1'b0;

always @(led_out) begin
    if (!led_out) begin
        $display($time, " << Camera initialization complete >>");
        $display($time, " << Start image receiving... >>");
    end
end

always @(cam_clock_counter) begin
    if (cam_clock_counter >= CAM_FRAME_CLK) begin
        $fclose(fd);
        $display();

        if (row_num != TARGET_IMAGE_HEIGHT)
            $display($time, " Error: image contains %0d rows. Expected %0d",
                     row_num, TARGET_IMAGE_HEIGHT);
        else
            $display($time, " << Frame writing complete >>");

        if (num_frames == 1) begin
            $display($time, " << Simulation complete >>");
            $finish;
        end else begin
            num_frames = #1 num_frames + 1;

            fd = $fopen("screen_image_2.ppm", "w");
            if (!fd) begin
                $display("Can't open image file for output");
                $finish;
            end else begin
                $fdisplay(fd, "P3");
                $fdisplay(fd, "%0d %0d", TARGET_IMAGE_WIDTH, TARGET_IMAGE_HEIGHT);
                $fdisplay(fd, "255");
            end

            row_pixels = 0;
            row_num = 0;
            cam_clock_counter = 0;
        end
    end
end

int row_pixels;
int row_num;

initial begin
    fd = $fopen("screen_image_1.ppm", "w");
    if (!fd) begin
        $display("Can't open image file for output");
        $finish;
    end else begin
        $fdisplay(fd, "P3");
        $fdisplay(fd, "%0d %0d", TARGET_IMAGE_WIDTH, TARGET_IMAGE_HEIGHT);
        $fdisplay(fd, "255");
    end
    row_pixels = 0;
    row_num = 0;
end

int red_part, green_part, blue_part;

always @(negedge LCD_CLK) begin
    if (LCD_DE) begin
        red_part[7:3] = #1 LCD_R;
        green_part[7:2] = #1 LCD_G;
        blue_part[7:3] = #1 LCD_B;

        #1 $fdisplay(fd, "%0d %0d %0d", red_part, green_part, blue_part);
        row_pixels = #1 row_pixels + 1;
    end

    if (row_pixels > 0 && LCD_HYNC) begin
        if (row_pixels != TARGET_IMAGE_WIDTH) begin
            #1 $display("Write %0d pixels to row. Expected %0d", row_pixels, TARGET_IMAGE_WIDTH);
            $finish;
        end else begin
            if (row_num % 10 == 0)
                $write("#");
            row_num += 1;
        end

        row_pixels = #1 0;
    end
end

`ifdef __ICARUS__
initial begin
    $dumpvars(0, clk, led_out, scl, sda);
end
`endif

endmodule

module delay (in, out);
  input  in;
  output out;
 
  assign out = in;
 
  specify
    (in => out) = (600,600);
  endspecify
endmodule
