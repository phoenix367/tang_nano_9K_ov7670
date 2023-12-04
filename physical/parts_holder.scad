module holder(holder_width = 165, holder_height = 150) {
    difference() {
        cube(size = [holder_width,holder_height,5], center = false);
        
        translate([3,3,3]) 
            cube(size = [holder_width - 6,holder_height - 6,15], center = false);
    };
}

module mount_holders(start_x, start_y) {
    holder_height = 10;
    holder_r = 5;
    
    pos_x = start_x;
    pos_y = start_y;
    
    for (i = [0:4]) {
        pos_x = (i > 1) ? start_x + 63.5 : start_x;
        pos_y = (i % 2) ? start_y + 116.84 : start_y;

        translate([pos_x, pos_y, 0]) {
            difference() {
                cylinder(h = holder_height, r = holder_r, $fs = 0.01);
                cylinder(h = holder_height + 1, r = 1, $fs = 0.01);
            }
        }
    }
}

module screen_holder() {
    screen_width = 105;
    screen_height = 67;
    screen_depth = 3;
    sceen_holder_depth = 10 + 1.6 + screen_depth;
    size_gap = 2;
    border_size = 3;
    
    difference() {
        cube(size = [screen_width + size_gap * 2 + border_size * 2,screen_height + size_gap * 2 + border_size * 2,sceen_holder_depth], center = false);
        
        translate([border_size, border_size, sceen_holder_depth - screen_depth]) 
            cube(size = [screen_width + size_gap * 2,screen_height + size_gap * 2,screen_depth + 1], center = false);

        translate([15, 15, sceen_holder_depth - 10]) 
            cube(size = [screen_width - 15,screen_height - 15,15], center = false);
        translate([border_size + 15, -1, sceen_holder_depth - screen_depth]) 
            cube(size = [screen_width - 30,screen_height,screen_depth + 1], center = false);
    };
}

holder_width = 165;
holder_height = 150;

union() {
    holder(holder_width = holder_width, holder_height = holder_height);
    mount_holders(10, holder_height / 2 - 116.84 / 2);
    
    rotate([0, 0, 270]) translate([-139, 80, 0])
        screen_holder();
}